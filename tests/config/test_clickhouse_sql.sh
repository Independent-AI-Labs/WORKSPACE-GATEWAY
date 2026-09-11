#!/bin/bash
set -euo pipefail

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
    _SELF="$SHG_SCRIPT_PATH"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
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

HAS_DB_RC=0
HAS_DB=$(grep -c 'CREATE DATABASE.*llm_gateway' "$SQL_FILE" ) || { HAS_DB_RC=$?; HAS_DB="0"; }
assert_eq "Creates database llm_gateway" "1" "$HAS_DB"

HAS_REQUEST_LOG_RC=0
HAS_REQUEST_LOG=$(grep -c 'CREATE TABLE.*request_log' "$SQL_FILE" ) || { HAS_REQUEST_LOG_RC=$?; HAS_REQUEST_LOG="0"; }
assert_eq "Creates table request_log" "1" "$HAS_REQUEST_LOG"

HAS_BILLING_LEDGER_RC=0
HAS_BILLING_LEDGER=$(grep -c 'CREATE TABLE IF NOT EXISTS llm_gateway.billing_ledger' "$SQL_FILE" ) || { HAS_BILLING_LEDGER_RC=$?; HAS_BILLING_LEDGER="0"; }
assert_eq "Creates table billing_ledger" "1" "$HAS_BILLING_LEDGER"

HAS_BILLING_DISC_RC=0
HAS_BILLING_DISC=$(grep -c 'CREATE TABLE IF NOT EXISTS llm_gateway.billing_discrepancies' "$SQL_FILE" ) || { HAS_BILLING_DISC_RC=$?; HAS_BILLING_DISC="0"; }
assert_eq "Creates table billing_discrepancies" "1" "$HAS_BILLING_DISC"

HAS_DECIMAL_RC=0
HAS_DECIMAL=$(grep -c 'cost.*Decimal64(6)' "$SQL_FILE" ) || { HAS_DECIMAL_RC=$?; HAS_DECIMAL="0"; }
assert_eq "billing_ledger has Decimal64(6) for cost" "true" "$(if [ "$HAS_DECIMAL" -ge 1 ]; then printf 'true'; else printf 'false'; fi)"

HAS_TTL_RC=0
HAS_TTL=$(grep -c 'INTERVAL 13 MONTH' "$SQL_FILE" ) || { HAS_TTL_RC=$?; HAS_TTL="0"; }
assert_eq "TTL 13 MONTH on tables" "true" "$(if [ "$HAS_TTL" -ge 2 ]; then printf 'true'; else printf 'false'; fi)"

HAS_PART_LIMITS_RC=0
HAS_PART_LIMITS=$(grep -c '^[[:space:]]*parts_to_throw_insert = 1000' "$SQL_FILE" ) || { HAS_PART_LIMITS_RC=$?; HAS_PART_LIMITS="0"; }
assert_eq "Created and existing MergeTree tables reject runaway part creation" "8" "$HAS_PART_LIMITS"

HAS_INACTIVE_PART_LIMITS_RC=0
HAS_INACTIVE_PART_LIMITS=$(grep -c 'inactive_parts_to_throw_insert = 1000' "$SQL_FILE" ) || { HAS_INACTIVE_PART_LIMITS_RC=$?; HAS_INACTIVE_PART_LIMITS="0"; }
assert_eq "Created and existing MergeTree tables reject runaway inactive parts" "8" "$HAS_INACTIVE_PART_LIMITS"

HAS_RUNTIME_PART_LIMITS_RC=0
HAS_RUNTIME_PART_LIMITS=$(grep -c '^ALTER TABLE.*MODIFY SETTING' "$SQL_FILE" ) || { HAS_RUNTIME_PART_LIMITS_RC=$?; HAS_RUNTIME_PART_LIMITS="0"; }
assert_eq "Existing MergeTree tables receive runtime part limits" "4" "$HAS_RUNTIME_PART_LIMITS"

HAS_TOTAL_PART_LIMITS_RC=0
HAS_TOTAL_PART_LIMITS=$(grep -c 'max_parts_in_total = 5000' "$SQL_FILE" ) || { HAS_TOTAL_PART_LIMITS_RC=$?; HAS_TOTAL_PART_LIMITS="0"; }
assert_eq "Created and existing MergeTree tables cap total parts" "8" "$HAS_TOTAL_PART_LIMITS"

ORDER_BY_LEADING_RC=0
ORDER_BY_LEADING=$(grep -o 'ORDER BY ([a-z_]*' "$SQL_FILE" ) || { ORDER_BY_LEADING_RC=$?; ORDER_BY_LEADING=""; }
LEADING_COUNT_RC=0
LEADING_COUNT=$(echo "$ORDER_BY_LEADING" | grep -c 'ORDER BY (provider\|ORDER BY (tenant_id\|ORDER BY (date' ) || { LEADING_COUNT_RC=$?; LEADING_COUNT="0"; }
assert_eq "ORDER BY leads with low-cardinality keys" "3" "$LEADING_COUNT"

HAS_PROMPT_TOKENS_RC=0
HAS_PROMPT_TOKENS=$(grep -c 'prompt_tokens' "$SQL_FILE" ) || { HAS_PROMPT_TOKENS_RC=$?; HAS_PROMPT_TOKENS="0"; }
assert_eq "Has prompt_tokens column" "true" "$(if [ "$HAS_PROMPT_TOKENS" -ge 2 ]; then printf 'true'; else printf 'false'; fi)"

HAS_COMPLETION_TOKENS_RC=0
HAS_COMPLETION_TOKENS=$(grep -c 'completion_tokens' "$SQL_FILE" ) || { HAS_COMPLETION_TOKENS_RC=$?; HAS_COMPLETION_TOKENS="0"; }
assert_eq "Has completion_tokens column" "true" "$(if [ "$HAS_COMPLETION_TOKENS" -ge 2 ]; then printf 'true'; else printf 'false'; fi)"

HAS_TOTAL_TOKENS_RC=0
HAS_TOTAL_TOKENS=$(grep -c 'total_tokens' "$SQL_FILE" ) || { HAS_TOTAL_TOKENS_RC=$?; HAS_TOTAL_TOKENS="0"; }
assert_eq "Has total_tokens column" "true" "$(if [ "$HAS_TOTAL_TOKENS" -ge 2 ]; then printf 'true'; else printf 'false'; fi)"

HAS_REQ_BODY_RC=0
HAS_REQ_BODY=$(grep -c 'req_body' "$SQL_FILE" ) || { HAS_REQ_BODY_RC=$?; HAS_REQ_BODY="0"; }
assert_eq "Has req_body column in request_log" "1" "$HAS_REQ_BODY"

HAS_UPSTREAM_TIME_RC=0
HAS_UPSTREAM_TIME=$(grep -c 'upstream_response_time_s' "$SQL_FILE" ) || { HAS_UPSTREAM_TIME_RC=$?; HAS_UPSTREAM_TIME="0"; }
assert_eq "Has upstream_response_time_s column" "1" "$HAS_UPSTREAM_TIME"

NO_OLD_LATENCY_RC=0
NO_OLD_LATENCY=$(grep -cE '^\s*latency_ms' "$SQL_FILE" ) || { NO_OLD_LATENCY_RC=$?; NO_OLD_LATENCY="0"; }
assert_eq "Old latency_ms column removed" "0" "$NO_OLD_LATENCY"

HAS_TENANT_ID_RC=0
HAS_TENANT_ID=$(grep -c 'tenant_id' "$SQL_FILE" ) || { HAS_TENANT_ID_RC=$?; HAS_TENANT_ID="0"; }
assert_eq "Has tenant_id column" "true" "$(if [ "$HAS_TENANT_ID" -ge 2 ]; then printf 'true'; else printf 'false'; fi)"

HAS_USER_ID_RC=0
HAS_USER_ID=$(grep -c 'user_id' "$SQL_FILE" ) || { HAS_USER_ID_RC=$?; HAS_USER_ID="0"; }
assert_eq "Has user_id column" "true" "$(if [ "$HAS_USER_ID" -ge 2 ]; then printf 'true'; else printf 'false'; fi)"

HAS_KEY_ID_RC=0
HAS_KEY_ID=$(grep -c 'key_id' "$SQL_FILE" ) || { HAS_KEY_ID_RC=$?; HAS_KEY_ID="0"; }
assert_eq "Has key_id column" "true" "$(if [ "$HAS_KEY_ID" -ge 1 ]; then printf 'true'; else printf 'false'; fi)"

HAS_SESSION_ID_RC=0
HAS_SESSION_ID=$(grep -c 'session_id' "$SQL_FILE" ) || { HAS_SESSION_ID_RC=$?; HAS_SESSION_ID="0"; }
assert_eq "Has session_id column" "true" "$(if [ "$HAS_SESSION_ID" -ge 1 ]; then printf 'true'; else printf 'false'; fi)"

HAS_USER_AGENT_RC=0
HAS_USER_AGENT=$(grep -c 'user_agent' "$SQL_FILE" ) || { HAS_USER_AGENT_RC=$?; HAS_USER_AGENT="0"; }
assert_eq "Has user_agent column" "true" "$(if [ "$HAS_USER_AGENT" -ge 1 ]; then printf 'true'; else printf 'false'; fi)"

HAS_USAGE_LOG_RC=0
HAS_USAGE_LOG=$(grep -c 'usage_log' "$SQL_FILE" ) || { HAS_USAGE_LOG_RC=$?; HAS_USAGE_LOG="0"; }
assert_eq "Has usage_log table" "true" "$(if [ "$HAS_USAGE_LOG" -ge 1 ]; then printf 'true'; else printf 'false'; fi)"

HAS_ABORTED_RC=0
HAS_ABORTED=$(grep -c 'aborted.*UInt8' "$SQL_FILE" ) || { HAS_ABORTED_RC=$?; HAS_ABORTED="0"; }
assert_eq "Has aborted UInt8 column in usage_log" "true" "$(if [ "$HAS_ABORTED" -ge 1 ]; then printf 'true'; else printf 'false'; fi)"

HAS_ABORTED_ALTER_RC=0
HAS_ABORTED_ALTER=$(grep -c 'ADD COLUMN IF NOT EXISTS aborted' "$SQL_FILE" ) || { HAS_ABORTED_ALTER_RC=$?; HAS_ABORTED_ALTER="0"; }
assert_eq "Has idempotent ALTER for aborted column" "1" "$HAS_ABORTED_ALTER"

HAS_IS_STREAM_RC=0
HAS_IS_STREAM=$(grep -c 'is_stream.*UInt8' "$SQL_FILE" ) || { HAS_IS_STREAM_RC=$?; HAS_IS_STREAM="0"; }
assert_eq "Has is_stream UInt8 column in usage_log" "true" "$(if [ "$HAS_IS_STREAM" -ge 1 ]; then printf 'true'; else printf 'false'; fi)"

HAS_IS_STREAM_ALTER_RC=0
HAS_IS_STREAM_ALTER=$(grep -c 'ADD COLUMN IF NOT EXISTS is_stream' "$SQL_FILE" ) || { HAS_IS_STREAM_ALTER_RC=$?; HAS_IS_STREAM_ALTER="0"; }
assert_eq "Has idempotent ALTER for is_stream column" "1" "$HAS_IS_STREAM_ALTER"

HAS_COST_RC=0
HAS_COST=$(grep -c 'cost.*Float64' "$SQL_FILE" ) || { HAS_COST_RC=$?; HAS_COST="0"; }
assert_eq "Has cost Float64 column in usage_log" "true" "$(if [ "$HAS_COST" -ge 1 ]; then printf 'true'; else printf 'false'; fi)"

HAS_COST_ALTER_RC=0
HAS_COST_ALTER=$(grep -c 'ADD COLUMN IF NOT EXISTS cost ' "$SQL_FILE" ) || { HAS_COST_ALTER_RC=$?; HAS_COST_ALTER="0"; }
assert_eq "Has idempotent ALTER for cost column" "1" "$HAS_COST_ALTER"

HAS_COST_SOURCE_RC=0
HAS_COST_SOURCE=$(grep -c "cost_source.*Enum8" "$SQL_FILE" ) || { HAS_COST_SOURCE_RC=$?; HAS_COST_SOURCE="0"; }
assert_eq "Has cost_source Enum8 column in usage_log" "true" "$(if [ "$HAS_COST_SOURCE" -ge 1 ]; then printf 'true'; else printf 'false'; fi)"

HAS_COST_SOURCE_ALTER_RC=0
HAS_COST_SOURCE_ALTER=$(grep -c 'ADD COLUMN IF NOT EXISTS cost_source' "$SQL_FILE" ) || { HAS_COST_SOURCE_ALTER_RC=$?; HAS_COST_SOURCE_ALTER="0"; }
assert_eq "Has idempotent ALTER for cost_source column" "1" "$HAS_COST_SOURCE_ALTER"

HAS_ENUM_VALUES_RC=0
HAS_ENUM_VALUES=$(grep -c "Enum8('upstream' = 0, 'computed' = 1, 'unknown' = 2)" "$SQL_FILE" ) || { HAS_ENUM_VALUES_RC=$?; HAS_ENUM_VALUES="0"; }
assert_eq "cost_source enum has upstream=0, computed=1, unknown=2" "true" "$(if [ "$HAS_ENUM_VALUES" -ge 1 ]; then printf 'true'; else printf 'false'; fi)"

HAS_BILLING_MV_RC=0
HAS_BILLING_MV=$(grep -c 'CREATE MATERIALIZED VIEW IF NOT EXISTS.*billing_ledger_mv' "$SQL_FILE" ) || { HAS_BILLING_MV_RC=$?; HAS_BILLING_MV="0"; }
assert_eq "Creates materialized view billing_ledger_mv" "1" "$HAS_BILLING_MV"

HAS_MV_TO_RC=0
HAS_MV_TO=$(grep -c 'TO llm_gateway.billing_ledger' "$SQL_FILE" ) || { HAS_MV_TO_RC=$?; HAS_MV_TO="0"; }
assert_eq "MV targets billing_ledger table" "1" "$HAS_MV_TO"

HAS_MV_FROM_USAGE_RC=0
HAS_MV_FROM_USAGE=$(grep -c 'FROM llm_gateway.usage_log' "$SQL_FILE" ) || { HAS_MV_FROM_USAGE_RC=$?; HAS_MV_FROM_USAGE="0"; }
assert_eq "MV selects FROM usage_log" "1" "$HAS_MV_FROM_USAGE"

HAS_MV_REQUEST_MODE_RC=0
HAS_MV_REQUEST_MODE=$(grep -c "request_mode" "$SQL_FILE" ) || { HAS_MV_REQUEST_MODE_RC=$?; HAS_MV_REQUEST_MODE="0"; }
assert_eq "MV has request_mode column" "true" "$(if [ "$HAS_MV_REQUEST_MODE" -ge 1 ]; then printf 'true'; else printf 'false'; fi)"

HAS_MV_CACHE_STATUS_RC=0
HAS_MV_CACHE_STATUS=$(grep -c "cache_status" "$SQL_FILE" ) || { HAS_MV_CACHE_STATUS_RC=$?; HAS_MV_CACHE_STATUS="0"; }
assert_eq "MV has cache_status column" "true" "$(if [ "$HAS_MV_CACHE_STATUS" -ge 1 ]; then printf 'true'; else printf 'false'; fi)"

HAS_MV_SUCCESS_RC=0
HAS_MV_SUCCESS=$(grep -c "aborted = 0" "$SQL_FILE" ) || { HAS_MV_SUCCESS_RC=$?; HAS_MV_SUCCESS="0"; }
assert_eq "MV derives success from aborted=0" "1" "$HAS_MV_SUCCESS"

# ── system log hygiene (text_log reached 143 GiB / 7.4B rows) ─────────
CH_LOG_XML="$REPO_ROOT/conf/clickhouse-disable-metric-logs.xml"

for table in metric_log asynchronous_metric_log text_log trace_log processors_profile_log; do
    HAS_REMOVE_RC=0
    HAS_REMOVE=$(grep -c "<${table} remove=\"1\"" "$CH_LOG_XML" ) || { HAS_REMOVE_RC=$?; HAS_REMOVE="0"; }
    assert_eq "ClickHouse ${table} flush disabled" "1" "$HAS_REMOVE"

    HAS_TRUNCATE_RC=0
    HAS_TRUNCATE=$(grep -c "TRUNCATE TABLE IF EXISTS system.${table};" "$SQL_FILE" ) || { HAS_TRUNCATE_RC=$?; HAS_TRUNCATE="0"; }
    assert_eq "init.sql self-heals system.${table}" "1" "$HAS_TRUNCATE"
done

summary
