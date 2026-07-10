#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RECONCILER="$REPO_ROOT/res/scripts/reconciler.sh"

CH_URL="http://localhost:8123"

pass=0
fail=0

check() {
    local desc="$1"
    local result="$2"
    if [ "$result" = "0" ]; then
        echo "[PASS] $desc"
        pass=$((pass + 1))
    else
        echo "[FAIL] $desc"
        fail=$((fail + 1))
    fi
}

ch_ping=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    "$CH_URL/ping" 2>/dev/null || echo "000")
if [ "$ch_ping" != "200" ]; then
    echo "[SKIP] ClickHouse not reachable, skipping reconciler execution tests"
    exit 0
fi

echo "[INFO] Running reconciler against ClickHouse..."
output=$(CLICKHOUSE_HOST=localhost CLICKHOUSE_PORT=8123 bash "$RECONCILER" 2>&1) || true

if grep -q "reconciler" <<< "$output"; then
    check "Reconciler produced output with prefix" "0"
else
    check "Reconciler produced output with prefix" "1"
    echo "[DEBUG] output: $output"
fi

if grep -q "completed for\|nothing to reconcile" <<< "$output"; then
    check "Reconciler completed or reported no records" "0"
else
    check "Reconciler completed or reported no records" "1"
fi

echo "[INFO] Testing reconciler error handling with bad host..."
error_output=$(CLICKHOUSE_HOST=invalid.invalid CLICKHOUSE_PORT=8123 bash "$RECONCILER" 2>&1) || true

if grep -q "ERROR" <<< "$error_output"; then
    check "Reconciler reports ERROR on bad host" "0"
else
    check "Reconciler reports ERROR on bad host" "1"
    echo "[DEBUG] error_output: $error_output"
fi

echo ""
echo "Reconciler execution tests: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi
