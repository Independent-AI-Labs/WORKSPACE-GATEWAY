#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RECONCILER="$REPO_ROOT/res/scripts/reconciler.sh"

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

bash -n "$RECONCILER"
check "Valid bash syntax" "$?"

grep -q 'set -euo pipefail' "$RECONCILER"
check "set -euo pipefail present" "$?"

grep -q ':-localhost' "$RECONCILER"
check "CLICKHOUSE_HOST has default (localhost)" "$?"

grep -q ':-8123' "$RECONCILER"
check "CLICKHOUSE_PORT has default" "$?"

grep -q 'exit 1' "$RECONCILER"
check "Error handling on query failure" "$?"

grep -q 'nothing to reconcile' "$RECONCILER"
check "Empty results handled" "$?"

grep -q 'request_log' "$RECONCILER"
check "Queries request_log not billing_ledger" "$?"

echo ""
echo "Reconciler tests: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi