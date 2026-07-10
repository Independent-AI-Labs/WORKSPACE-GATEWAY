#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/res/docker/docker-compose.yml"

export PATH="$PATH:$REPO_ROOT/.venv/bin"

pass=0
fail=0

teardown() {
    if [ "${EXTERNAL_STACK:-0}" = "1" ]; then
        echo "[INFO] Stack was already running: leaving it up."
        echo ""
        echo "Integration tests: $pass passed, $fail failed"
        if [ "$fail" -gt 0 ]; then
            exit 1
        fi
        exit 0
    fi
    if [ -n "${KEEP_STACK_UP_FOR_E2E:-}" ]; then
        echo "[INFO] Keeping stack up for E2E tests (KEEP_STACK_UP_FOR_E2E=1)"
        echo ""
        echo "Integration tests: $pass passed, $fail failed"
        if [ "$fail" -gt 0 ]; then
            exit 1
        fi
        exit 0
    fi
    echo "[INFO] Runner tearing down stack..."
    podman-compose -f "$COMPOSE_FILE" down || echo "[WARN] teardown failed (rc=$?)"
    echo ""
    echo "Integration tests: $pass passed, $fail failed"
    if [ "$fail" -gt 0 ]; then
        exit 1
    fi
    exit 0
}
trap teardown EXIT

stack_is_up() {
    podman ps --format '{{.Names}}' | grep -q apisix
}

# Auto-detect: if the stack is already running, treat it as external and
# NEVER tear it down.  Only start/teardown our own stack if nothing is running.
if [ "${EXTERNAL_STACK:-0}" != "1" ]; then
    if stack_is_up; then
        export EXTERNAL_STACK=1
        echo "[INFO] Stack is already running: tests will NOT tear it down."
    else
        export EXTERNAL_STACK=0
        echo "[INFO] Stack is not running: tests will start and tear down their own."
    fi
fi

echo "=== Stage 4: Podman Stack Integration Tests ==="
echo ""

if [ "$EXTERNAL_STACK" = "1" ]; then
    echo "[INFO] Stack already running: skipping stack startup test."
    pass=$((pass + 1))
else
    export KEEP_STACK_UP=1
    if bash "$SCRIPT_DIR/test_stack_up.sh"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
    fi
    unset KEEP_STACK_UP
fi

if stack_is_up; then
    for test_script in test_key_resolver.sh test_route_relay.sh test_prometheus.sh test_grafana.sh test_dashboard_queries.sh test_grafana_ds_proxy.sh test_grafana_panels.sh; do
        echo ""
        echo "--- $test_script ---"
        if bash "$SCRIPT_DIR/$test_script"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    done
else
    echo "[WARN] Stack is not running; skipping black-box tests"
    fail=$((fail + 1))
fi

if stack_is_up; then
    # Local-llamafile-driven e2e tests. They SKIP cleanly (exit 0) when the
    # VM llamafile server is not reachable, so they can run unconditionally
    # in CI without a local LLM. No OPENCODE_API_KEY needed: the local LLM
    # serves real 200 responses with a usage object, which the zero-credit
    # opencode upstream cannot.
    for test_script in test_llamafile_e2e.sh test_event_id_alignment.sh test_data_flow.sh test_cost_e2e.sh test_reconciler_exec.sh; do
        echo ""
        echo "--- $test_script ---"
        if bash "$SCRIPT_DIR/$test_script"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    done
else
    echo "[INFO] Skipping local-LLM e2e tests (stack not running)"
fi

echo ""
echo "[INFO] Stack integration tests complete."