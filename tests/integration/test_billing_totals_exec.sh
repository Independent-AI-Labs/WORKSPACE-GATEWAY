#!/bin/bash
set -euo pipefail

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
    _SELF="$SHG_SCRIPT_PATH"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOTALS="$REPO_ROOT/res/scripts/billing-totals.sh"

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

ch_ping_RC=0
ch_ping=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 5 \
    "$CH_URL/ping" ) || { ch_ping_RC=$?; ch_ping="000"; }
if [ "$ch_ping" != "200" ]; then
    echo "[SKIP] ClickHouse not reachable, skipping billing-totals execution tests"
    exit 0
fi

echo "[INFO] Running billing-totals against ClickHouse..."
if ! output=$(CLICKHOUSE_HOST=localhost CLICKHOUSE_PORT=8123 bash "$TOTALS" 2>&1); then echo "[INFO] billing-totals exited non-zero, output captured" >&2; fi

if grep -q "billing-totals" <<< "$output"; then
    check "Billing totals produced output with prefix" "0"
else
    check "Billing totals produced output with prefix" "1"
    echo "[DEBUG] output: $output"
fi

if grep -q "completed for\|nothing to report" <<< "$output"; then
    check "Billing totals completed or reported no records" "0"
else
    check "Billing totals completed or reported no records" "1"
fi

echo "[INFO] Testing billing-totals error handling with bad host..."
if ! error_output=$(bash "$TOTALS" --host invalid.invalid --port 8123 2>&1); then echo "[INFO] billing-totals exited non-zero on bad host (expected)" >&2; fi

if grep -q "ERROR" <<< "$error_output"; then
    check "Billing totals reports ERROR on bad host" "0"
else
    check "Billing totals reports ERROR on bad host" "1"
    echo "[DEBUG] error_output: $error_output"
fi

echo ""
echo "Billing totals execution tests: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi
