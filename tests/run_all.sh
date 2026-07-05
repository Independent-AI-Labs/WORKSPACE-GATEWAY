#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    source "$REPO_ROOT/.env" || exit 1
    set +a
fi

export PATH="$PATH:$HOME/.venv/bin"

pass=0
fail=0

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

run_stage 2 "Config Validation" "config/run.sh"

run_stage 3 "Reconciler Tests" "reconciler/test_reconciler.sh"

run_stage 4 "Integration Tests" "integration/run.sh"

run_stage 5 "CI Hook Verification" "ci/test_hooks.sh"

if [ -n "${OPENCODE_ZEN_API_KEY:-}" ]; then
    run_stage 6 "E2E Zen API Tests" "e2e/run.sh"
else
    echo ""
    echo "========== Stage 6: E2E Zen API Tests =========="
    echo "[SKIP] OPENCODE_ZEN_API_KEY not set"
fi

echo ""
echo "=========================================="
echo "Overall: $pass stages passed, $fail stages failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi