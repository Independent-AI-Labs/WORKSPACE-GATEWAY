#!/bin/bash
set -euo pipefail

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
    _SELF="$SHG_SCRIPT_PATH"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOTALS="$REPO_ROOT/res/scripts/billing-totals.sh"

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

bash -n "$TOTALS"
check "Valid bash syntax" "$?"

grep -q 'set -euo pipefail' "$TOTALS"
check "set -euo pipefail present" "$?"

grep -q ':-localhost' "$TOTALS"
check "CLICKHOUSE_HOST has default (localhost)" "$?"

grep -q ':-8123' "$TOTALS"
check "CLICKHOUSE_PORT has default" "$?"

grep -q 'exit 1' "$TOTALS"
check "Error handling on query failure" "$?"

grep -q 'nothing to report' "$TOTALS"
check "Empty results handled" "$?"

grep -q 'request_log' "$TOTALS"
check "Queries request_log not billing_ledger" "$?"

echo ""
echo "Billing totals tests: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi
