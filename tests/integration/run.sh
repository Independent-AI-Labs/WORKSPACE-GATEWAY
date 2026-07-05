#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/res/docker/docker-compose.yml"

export PATH="$PATH:$HOME/.venv/bin"

pass=0
fail=0

teardown() {
    echo "[INFO] Runner tearing down stack..."
    podman-compose -f "$COMPOSE_FILE" down 2>/dev/null || true
    echo ""
    echo "Integration tests: $pass passed, $fail failed"
    if [ "$fail" -gt 0 ]; then
        exit 1
    fi
    exit 0
}
trap teardown EXIT

stack_is_up() {
    podman ps --format '{{.Names}}' 2>/dev/null | grep -q apisix
}

echo "=== Stage 4: Podman Stack Integration Tests ==="
echo ""

export KEEP_STACK_UP=1
if bash "$SCRIPT_DIR/test_stack_up.sh"; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
fi
unset KEEP_STACK_UP

if stack_is_up; then
    for test_script in test_key_auth.sh test_route_relay.sh; do
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

echo ""
echo "[INFO] Stack integration tests complete."