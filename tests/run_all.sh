#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    source "$REPO_ROOT/.env" || exit 1
    set +a
fi

export PATH="$PATH:$REPO_ROOT/.venv/bin"

pass=0
fail=0

stack_is_up() {
    podman ps --format '{{.Names}}' | grep -q apisix
}

if stack_is_up; then
    export EXTERNAL_STACK=1
    echo "[INFO] Stack is already running: tests will NOT tear it down."
else
    export EXTERNAL_STACK=0
    echo "[INFO] Stack is not running: tests will start and tear down their own."
fi

run_stage() {
    local stage_num="$1"
    local stage_name="$2"
    local runner="$3"

    echo ""
    echo "========== Stage $stage_num: $stage_name =========="
    if bash "$SCRIPT_DIR/$runner"; then
        echo "[PASS] Stage $stage_num: $stage_name"
        pass=$((pass + 1))
    else
        echo "[FAIL] Stage $stage_num: $stage_name"
        fail=$((fail + 1))
    fi
}

run_stage 1 "Lua Unit Tests" "lua/run.sh"

run_stage 2 "Script Tests" "scripts/run.sh"

run_stage 3 "Config Validation" "config/run.sh"

run_stage 4 "Reconciler Tests" "reconciler/test_reconciler.sh"

if [ -n "${OPENCODE_API_KEY:-}" ]; then
    export KEEP_STACK_UP_FOR_E2E=1
fi

run_stage 5 "Integration Tests" "integration/run.sh"

run_stage 6 "CI Hook Verification" "ci/test_hooks.sh"

if [ -n "${OPENCODE_API_KEY:-}" ]; then
    run_stage 7 "E2E Live API Tests" "e2e/run.sh"
else
    echo ""
    echo "========== Stage 7: E2E Live API Tests =========="
    echo "[SKIP] OPENCODE_API_KEY not set"
fi

if [ -n "${KEEP_STACK_UP_FOR_E2E:-}" ] && [ "${EXTERNAL_STACK:-0}" != "1" ]; then
    echo ""
    echo "[INFO] Tearing down test stack after all tests..."
    podman-compose -f "$REPO_ROOT/res/docker/docker-compose.yml" down || echo "[WARN] teardown failed (rc=$?)"
elif [ "${EXTERNAL_STACK:-0}" = "1" ]; then
    echo ""
    echo "[INFO] Stack was already running: leaving it up."
fi

echo ""
echo "=========================================="
echo "Overall: $pass stages passed, $fail stages failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi