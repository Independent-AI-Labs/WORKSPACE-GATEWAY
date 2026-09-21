#!/bin/bash
set -euo pipefail

# tests/integration/test_recalc_costs_run.sh
# Black-box test of res/scripts/recalc-costs.sh against the running stack.
# Default: dry run over a 5-row batch (writes nothing).
# RECALC_APPLY=1: also applies the small batch (verified backup) and then
# re-runs to prove idempotent convergence. Uses the full safety path the
# operator would use. Skips cleanly when the stack is not up.

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
    _SELF="$SHG_SCRIPT_PATH"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    if ! source "$REPO_ROOT/.env"; then
        echo "[FAIL] could not source $REPO_ROOT/.env" >&2
        exit 1
    fi
    set +a
fi

PODMAN_BIN="${PODMAN_BIN:-${PODMAN_PATH:-podman}}"
RECALC="$REPO_ROOT/res/scripts/recalc-costs.sh"
LIMIT="${1:-${RECALC_LIMIT:-5}}"
APPLY="${2:-${RECALC_APPLY:-0}}"
if [ "$#" -ge 2 ]; then
    shift 2
fi
EXTRA_ARGS=("$@")

pass=0
fail=0

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "[PASS] $desc"
        pass=$((pass + 1))
    else
        echo "[FAIL] $desc -- missing: [$needle]"
        echo "--- output ---"
        echo "$haystack"
        echo "--------------"
        fail=$((fail + 1))
    fi
}

if ! "$PODMAN_BIN" ps --filter label=io.podman.compose.project=docker \
        --format '{{.Names}}' | grep -q apisix; then
    echo "[SKIP] stack is not running; recalc-costs live test skipped"
    exit 0
fi

echo "=== recalc-costs.sh: dry run (limit=$LIMIT) ==="
DRY_RC=0
DRY_OUT=$(bash "$RECALC" --limit "$LIMIT" "${EXTRA_ARGS[@]}" 2>&1) || DRY_RC=$?
echo "$DRY_OUT"
if [ "$DRY_RC" -ne 0 ]; then
    echo "[FAIL] dry run exited $DRY_RC"
    fail=$((fail + 1))
fi
assert_contains "dry run reports candidates" "$DRY_OUT" "candidate rows:"
assert_contains "dry run leaves a run id" "$DRY_OUT" "run_id=run-"
if [[ "$DRY_OUT" == *"already reconciled"* ]] || [[ "$DRY_OUT" == *"nothing to do."* ]]; then
    echo "[PASS] dry run found nothing to change (idempotent no-op)"
    pass=$((pass + 1))
else
    assert_contains "dry run takes no backup and writes nothing" "$DRY_OUT" "DRY RUN"
fi

if [ "$APPLY" != "1" ]; then
    echo ""
    echo "recalc-costs live test: $pass passed, $fail failed"
    [ "$fail" -eq 0 ] || exit 1
    echo "[INFO] set RECALC_APPLY=1 to exercise the apply path"
    exit 0
fi

echo ""
echo "=== recalc-costs.sh: apply small batch (limit=$LIMIT, mandatory backup) ==="
APPLY_RC=0
APPLY_OUT=$(bash "$RECALC" --limit "$LIMIT" --apply "${EXTRA_ARGS[@]}" 2>&1) || APPLY_RC=$?
echo "$APPLY_OUT"
if [ "$APPLY_RC" -ne 0 ]; then
    echo "[FAIL] apply exited $APPLY_RC"
    fail=$((fail + 1))
fi
APPLY_NOOP=0
if [[ "$APPLY_OUT" == *"already reconciled"* ]]; then
    APPLY_NOOP=1
    echo "[PASS] apply found nothing to change (no backup needed; idempotent no-op)"
    pass=$((pass + 1))
elif [ "$APPLY_RC" -eq 0 ]; then
    assert_contains "apply verifies the backup" "$APPLY_OUT" "backup verified:"
fi
assert_contains "apply reports the result" "$APPLY_OUT" "applied="
if [[ "$APPLY_OUT" != *"applied=0 failed=0"* ]] && [[ "$APPLY_OUT" != *"already reconciled"* ]]; then
    assert_contains "apply had no failures" "$APPLY_OUT" "failed=0"
else
    echo "[PASS] apply had no failures"
    pass=$((pass + 1))
fi

if [ "$APPLY_NOOP" -eq 1 ]; then
    echo "[PASS] converged DB re-applies nothing (idempotent)"
    pass=$((pass + 1))
    echo ""
    echo "recalc-costs live test: $pass passed, $fail failed"
    [ "$fail" -eq 0 ] || exit 1
    exit 0
fi

echo ""
echo "=== recalc-costs.sh: re-run must not re-apply corrected rows (idempotent) ==="
# The first event id the apply touched, taken from its own sample block.
FIRST_EID=""
while IFS= read -r line; do
    case "$line" in
        "  "*"new="*)
            FIRST_EID="${line#"  "}"
            FIRST_EID="${FIRST_EID%% *}"
            break
            ;;
    esac
done <<< "$APPLY_OUT"

AGAIN_RC=0
AGAIN_OUT=$(bash "$RECALC" --limit "$LIMIT" --apply "${EXTRA_ARGS[@]}" 2>&1) || AGAIN_RC=$?
echo "$AGAIN_OUT"
if [ "$AGAIN_RC" -ne 0 ]; then
    echo "[FAIL] second pass exited $AGAIN_RC"
    fail=$((fail + 1))
fi
if [ -z "$FIRST_EID" ]; then
    echo "[FAIL] could not parse an event id from the apply output"
    fail=$((fail + 1))
elif [[ "$AGAIN_OUT" == *"$FIRST_EID"* ]]; then
    echo "[FAIL] corrected row $FIRST_EID was re-emitted (not idempotent)"
    fail=$((fail + 1))
else
    echo "[PASS] corrected row $FIRST_EID is not re-emitted"
    pass=$((pass + 1))
fi

echo ""
echo "recalc-costs live test: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi
