#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass=0
fail=0

assert_eq() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "[PASS] $desc"
        pass=$((pass + 1))
    else
        echo "[FAIL] $desc -- expected: $expected, actual: $actual"
        fail=$((fail + 1))
    fi
}

summary() {
    echo ""
    echo "test_clickhouse_sql.sh: $pass passed, $fail failed"
    if [ "$fail" -gt 0 ]; then
        exit 1
    fi
}

SQL_FILE="$REPO_ROOT/conf/clickhouse-init.sql"

HAS_DB=$(grep -c 'CREATE DATABASE.*llm_gateway' "$SQL_FILE" || true)
assert_eq "Creates database llm_gateway" "1" "$HAS_DB"

HAS_REQUEST_LOG=$(grep -c 'CREATE TABLE.*request_log' "$SQL_FILE" || true)
assert_eq "Creates table request_log" "1" "$HAS_REQUEST_LOG"

HAS_BILLING_LEDGER=$(grep -c 'billing_ledger' "$SQL_FILE" || true)
assert_eq "Creates table billing_ledger" "1" "$HAS_BILLING_LEDGER"

HAS_BILLING_DISC=$(grep -c 'billing_discrepancies' "$SQL_FILE" || true)
assert_eq "Creates table billing_discrepancies" "1" "$HAS_BILLING_DISC"

HAS_DECIMAL=$(grep -c 'cost.*Decimal64(6)' "$SQL_FILE" || true)
assert_eq "billing_ledger has Decimal64(6) for cost" "1" "$HAS_DECIMAL"

HAS_TTL=$(grep -c 'INTERVAL 13 MONTH' "$SQL_FILE" || true)
assert_eq "TTL 13 MONTH on tables" "true" "$([ "$HAS_TTL" -ge 2 ] && echo true || echo false)"

ORDER_BY_LEADING=$(grep -o 'ORDER BY ([a-z_]*' "$SQL_FILE" || true)
LEADING_COUNT=$(echo "$ORDER_BY_LEADING" | grep -c 'ORDER BY (provider\|ORDER BY (tenant_id\|ORDER BY (date' || true)
assert_eq "ORDER BY leads with low-cardinality keys" "3" "$LEADING_COUNT"

HAS_PROMPT_TOKENS=$(grep -c 'prompt_tokens' "$SQL_FILE" || true)
assert_eq "Has prompt_tokens column" "true" "$([ "$HAS_PROMPT_TOKENS" -ge 2 ] && echo true || echo false)"

HAS_COMPLETION_TOKENS=$(grep -c 'completion_tokens' "$SQL_FILE" || true)
assert_eq "Has completion_tokens column" "true" "$([ "$HAS_COMPLETION_TOKENS" -ge 2 ] && echo true || echo false)"

HAS_TOTAL_TOKENS=$(grep -c 'total_tokens' "$SQL_FILE" || true)
assert_eq "Has total_tokens column" "true" "$([ "$HAS_TOTAL_TOKENS" -ge 2 ] && echo true || echo false)"

HAS_REQ_BODY=$(grep -c 'req_body' "$SQL_FILE" || true)
assert_eq "Has req_body column in request_log" "1" "$HAS_REQ_BODY"

HAS_UPSTREAM_TIME=$(grep -c 'upstream_response_time_s' "$SQL_FILE" || true)
assert_eq "Has upstream_response_time_s column" "1" "$HAS_UPSTREAM_TIME"

NO_OLD_LATENCY=$(grep -cE '^\s*latency_ms' "$SQL_FILE" || true)
assert_eq "Old latency_ms column removed" "0" "$NO_OLD_LATENCY"

HAS_TENANT_ID=$(grep -c 'tenant_id' "$SQL_FILE" || true)
assert_eq "Has tenant_id column" "true" "$([ "$HAS_TENANT_ID" -ge 2 ] && echo true || echo false)"

HAS_USER_ID=$(grep -c 'user_id' "$SQL_FILE" || true)
assert_eq "Has user_id column" "true" "$([ "$HAS_USER_ID" -ge 2 ] && echo true || echo false)"

HAS_KEY_ID=$(grep -c 'key_id' "$SQL_FILE" || true)
assert_eq "Has key_id column" "true" "$([ "$HAS_KEY_ID" -ge 1 ] && echo true || echo false)"

HAS_SESSION_ID=$(grep -c 'session_id' "$SQL_FILE" || true)
assert_eq "Has session_id column" "true" "$([ "$HAS_SESSION_ID" -ge 1 ] && echo true || echo false)"

HAS_USER_AGENT=$(grep -c 'user_agent' "$SQL_FILE" || true)
assert_eq "Has user_agent column" "true" "$([ "$HAS_USER_AGENT" -ge 1 ] && echo true || echo false)"

HAS_USAGE_LOG=$(grep -c 'usage_log' "$SQL_FILE" || true)
assert_eq "Has usage_log table" "true" "$([ "$HAS_USAGE_LOG" -ge 1 ] && echo true || echo false)"

HAS_ABORTED=$(grep -c 'aborted.*UInt8' "$SQL_FILE" || true)
assert_eq "Has aborted UInt8 column in usage_log" "true" "$([ "$HAS_ABORTED" -ge 1 ] && echo true || echo false)"

HAS_ABORTED_ALTER=$(grep -c 'ADD COLUMN IF NOT EXISTS aborted' "$SQL_FILE" || true)
assert_eq "Has idempotent ALTER for aborted column" "1" "$HAS_ABORTED_ALTER"

HAS_IS_STREAM=$(grep -c 'is_stream.*UInt8' "$SQL_FILE" || true)
assert_eq "Has is_stream UInt8 column in usage_log" "true" "$([ "$HAS_IS_STREAM" -ge 1 ] && echo true || echo false)"

HAS_IS_STREAM_ALTER=$(grep -c 'ADD COLUMN IF NOT EXISTS is_stream' "$SQL_FILE" || true)
assert_eq "Has idempotent ALTER for is_stream column" "1" "$HAS_IS_STREAM_ALTER"

HAS_COST=$(grep -c 'cost.*Float64' "$SQL_FILE" || true)
assert_eq "Has cost Float64 column in usage_log" "true" "$([ "$HAS_COST" -ge 1 ] && echo true || echo false)"

HAS_COST_ALTER=$(grep -c 'ADD COLUMN IF NOT EXISTS cost ' "$SQL_FILE" || true)
assert_eq "Has idempotent ALTER for cost column" "1" "$HAS_COST_ALTER"

HAS_COST_SOURCE=$(grep -c "cost_source.*Enum8" "$SQL_FILE" || true)
assert_eq "Has cost_source Enum8 column in usage_log" "true" "$([ "$HAS_COST_SOURCE" -ge 1 ] && echo true || echo false)"

HAS_COST_SOURCE_ALTER=$(grep -c 'ADD COLUMN IF NOT EXISTS cost_source' "$SQL_FILE" || true)
assert_eq "Has idempotent ALTER for cost_source column" "1" "$HAS_COST_SOURCE_ALTER"

HAS_ENUM_VALUES=$(grep -c "Enum8('upstream' = 0, 'computed' = 1, 'unknown' = 2)" "$SQL_FILE" || true)
assert_eq "cost_source enum has upstream=0, computed=1, unknown=2" "true" "$([ "$HAS_ENUM_VALUES" -ge 1 ] && echo true || echo false)"

summary