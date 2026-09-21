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
assert_eq "Created and existing MergeTree tables reject runaway part creation" "9" "$HAS_PART_LIMITS"

HAS_INACTIVE_PART_LIMITS_RC=0
HAS_INACTIVE_PART_LIMITS=$(grep -c 'inactive_parts_to_throw_insert = 1000' "$SQL_FILE" ) || { HAS_INACTIVE_PART_LIMITS_RC=$?; HAS_INACTIVE_PART_LIMITS="0"; }
assert_eq "Created and existing MergeTree tables reject runaway inactive parts" "9" "$HAS_INACTIVE_PART_LIMITS"

HAS_RUNTIME_PART_LIMITS_RC=0
HAS_RUNTIME_PART_LIMITS=$(grep -c '^ALTER TABLE.*MODIFY SETTING' "$SQL_FILE" ) || { HAS_RUNTIME_PART_LIMITS_RC=$?; HAS_RUNTIME_PART_LIMITS="0"; }
assert_eq "Existing MergeTree tables receive runtime part limits" "4" "$HAS_RUNTIME_PART_LIMITS"

HAS_TOTAL_PART_LIMITS_RC=0
HAS_TOTAL_PART_LIMITS=$(grep -c 'max_parts_in_total = 5000' "$SQL_FILE" ) || { HAS_TOTAL_PART_LIMITS_RC=$?; HAS_TOTAL_PART_LIMITS="0"; }
assert_eq "Created and existing MergeTree tables cap total parts" "9" "$HAS_TOTAL_PART_LIMITS"

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

# ── usefulness telemetry: TTFT columns, MV wiring, request_signals ──────
HAS_TTFT_FB_RC=0
HAS_TTFT_FB=$(grep -c 'ttft_first_byte_ms.*UInt32' "$SQL_FILE" ) || { HAS_TTFT_FB_RC=$?; HAS_TTFT_FB="0"; }
assert_eq "Has ttft_first_byte_ms UInt32 in usage_log" "true" "$(if [ "$HAS_TTFT_FB" -ge 2 ]; then printf 'true'; else printf 'false'; fi)"

HAS_TTFT_C_RC=0
HAS_TTFT_C=$(grep -c 'ttft_content_ms.*UInt32' "$SQL_FILE" ) || { HAS_TTFT_C_RC=$?; HAS_TTFT_C="0"; }
assert_eq "Has ttft_content_ms UInt32 in usage_log" "true" "$(if [ "$HAS_TTFT_C" -ge 2 ]; then printf 'true'; else printf 'false'; fi)"

HAS_DURATION_RC=0
HAS_DURATION=$(grep -c 'duration_ms.*UInt32' "$SQL_FILE" ) || { HAS_DURATION_RC=$?; HAS_DURATION="0"; }
assert_eq "Has duration_ms UInt32 in usage_log" "true" "$(if [ "$HAS_DURATION" -ge 2 ]; then printf 'true'; else printf 'false'; fi)"

HAS_TTFT_ALTER_RC=0
HAS_TTFT_ALTER=$(grep -c 'ADD COLUMN IF NOT EXISTS ttft_content_ms' "$SQL_FILE" ) || { HAS_TTFT_ALTER_RC=$?; HAS_TTFT_ALTER="0"; }
assert_eq "Has idempotent ALTER for ttft_content_ms column" "1" "$HAS_TTFT_ALTER"

MV_WIRES_TTFT_RC=0
MV_WIRES_TTFT=$(grep -c 'ttft_content_ms.*AS ttft_ms' "$SQL_FILE" ) || { MV_WIRES_TTFT_RC=$?; MV_WIRES_TTFT="0"; }
assert_eq "MV wires ttft_content_ms into billing_ledger.ttft_ms" "1" "$MV_WIRES_TTFT"

MV_WIRES_DURATION_RC=0
MV_WIRES_DURATION=$(grep -c 'duration_ms.*AS llm_latency_ms' "$SQL_FILE" ) || { MV_WIRES_DURATION_RC=$?; MV_WIRES_DURATION="0"; }
assert_eq "MV wires duration_ms into billing_ledger.llm_latency_ms" "1" "$MV_WIRES_DURATION"

NO_MV_ZERO_TTFT_RC=0
NO_MV_ZERO_TTFT=$(awk '/CREATE MATERIALIZED VIEW.*billing_ledger_mv/,/FROM llm_gateway.usage_log/' "$SQL_FILE" | grep -cE '^\s*0\s+AS (ttft_ms|llm_latency_ms)' ) || { NO_MV_ZERO_TTFT_RC=$?; NO_MV_ZERO_TTFT="0"; }
assert_eq "MV no longer hardcodes zero ttft_ms/llm_latency_ms" "0" "$NO_MV_ZERO_TTFT"

HAS_REQUEST_SIGNALS_RC=0
HAS_REQUEST_SIGNALS=$(grep -c 'CREATE TABLE IF NOT EXISTS llm_gateway.request_signals' "$SQL_FILE" ) || { HAS_REQUEST_SIGNALS_RC=$?; HAS_REQUEST_SIGNALS="0"; }
assert_eq "Creates table request_signals" "1" "$HAS_REQUEST_SIGNALS"

HAS_SIGNAL_WEIGHT_RC=0
HAS_SIGNAL_WEIGHT=$(grep -c 'signal_weight.*Float32' "$SQL_FILE" ) || { HAS_SIGNAL_WEIGHT_RC=$?; HAS_SIGNAL_WEIGHT="0"; }
assert_eq "request_signals carries valence-factored signal_weight" "1" "$HAS_SIGNAL_WEIGHT"

MIG_UP="$REPO_ROOT/conf/migrations/000008_add_ttft_duration.up.sql"
MIG_DOWN="$REPO_ROOT/conf/migrations/000008_add_ttft_duration.down.sql"
MIG_UP_TTFT_RC=0
MIG_UP_TTFT=$(grep -c 'ADD COLUMN IF NOT EXISTS ttft_first_byte_ms' "$MIG_UP" ) || { MIG_UP_TTFT_RC=$?; MIG_UP_TTFT="0"; }
assert_eq "migration 000008 up adds ttft_first_byte_ms" "1" "$MIG_UP_TTFT"
MIG_UP_MV_RC=0
MIG_UP_MV=$(grep -c 'DROP TABLE IF EXISTS llm_gateway.billing_ledger_mv' "$MIG_UP" ) || { MIG_UP_MV_RC=$?; MIG_UP_MV="0"; }
assert_eq "migration 000008 recreates the frozen MV SELECT" "1" "$MIG_UP_MV"
MIG_DOWN_COLS_RC=0
MIG_DOWN_COLS=$(grep -c 'DROP COLUMN IF EXISTS duration_ms' "$MIG_DOWN" ) || { MIG_DOWN_COLS_RC=$?; MIG_DOWN_COLS="0"; }
assert_eq "migration 000008 down drops timing columns" "1" "$MIG_DOWN_COLS"

# --rebuild DDL extraction (crunch-usefulness.sh --rebuild sources the
# request_signals CREATE verbatim from clickhouse-init.sql; the awk range
# must yield a complete statement).
DDL_EXTRACT="$(awk '/^CREATE TABLE IF NOT EXISTS llm_gateway\.request_signals \(/,/;$/' "$SQL_FILE")"
DDL_HAS_ENGINE_RC=0
DDL_HAS_ENGINE=$(printf '%s' "$DDL_EXTRACT" | grep -c 'ENGINE = ReplacingMergeTree') || { DDL_HAS_ENGINE_RC=$?; DDL_HAS_ENGINE="0"; }
assert_eq "rebuild DDL extraction finds the engine clause" "1" "$DDL_HAS_ENGINE"
DDL_ENDS_RC=0
DDL_ENDS=$(printf '%s\n' "$DDL_EXTRACT" | grep -c 'max_parts_in_total = 5000' ) || { DDL_ENDS_RC=$?; DDL_ENDS="0"; }
assert_eq "rebuild DDL extraction includes the final SETTINGS line" "1" "$DDL_ENDS"

# Friction telemetry (REQ FR-8): migration 000009 columns, canonical DDL,
# marker extraction SQL wired into the crunch INSERT path.
MIG9_UP="$REPO_ROOT/conf/migrations/000009_add_friction_columns.up.sql"
MIG9_UP_RC=0
MIG9_UP=$(grep -c 'ADD COLUMN IF NOT EXISTS guard_blocks UInt16 DEFAULT 0' "$MIG9_UP" ) || { MIG9_UP_RC=$?; MIG9_UP="0"; }
assert_eq "migration 000009 adds guard_blocks" "1" "$MIG9_UP"
FRICTION_COLS_RC=0
FRICTION_COLS=$(grep -cE 'guard_blocks +UInt16|guard_rules +Array\(String\)|user_rejections +UInt16|rule_denials +UInt16' "$SQL_FILE" ) || { FRICTION_COLS_RC=$?; FRICTION_COLS="0"; }
assert_eq "init.sql request_signals carries all 4 friction columns" "4" "$FRICTION_COLS"
CRUNCH="$REPO_ROOT/res/scripts/crunch-usefulness.sh"
MARKER_BASH_RC=0
MARKER_BASH=$(grep -c "countMatches(b.req_body, 'BLOCKED: bash ')" "$CRUNCH" ) || { MARKER_BASH_RC=$?; MARKER_BASH="0"; }
assert_eq "crunch counts shell-guard BLOCKED markers" "1" "$MARKER_BASH"
MARKER_TS_RC=0
MARKER_TS=$(grep -c "countMatches(b.req_body, 'BLOCKED: ts=')" "$CRUNCH" ) || { MARKER_TS_RC=$?; MARKER_TS="0"; }
assert_eq "crunch counts git-guard BLOCKED markers" "1" "$MARKER_TS"
MARKER_REJ_RC=0
MARKER_REJ=$(grep -c "countMatches(b.req_body, 'The user rejected permission to use this specific tool call')" "$CRUNCH" ) || { MARKER_REJ_RC=$?; MARKER_REJ="0"; }
assert_eq "crunch counts opencode user-rejection markers" "1" "$MARKER_REJ"
MARKER_RULE_RC=0
MARKER_RULE=$(grep -c "countMatches(b.req_body, 'The user has specified a rule which prevents you from using this specific tool call')" "$CRUNCH" ) || { MARKER_RULE_RC=$?; MARKER_RULE="0"; }
assert_eq "crunch counts opencode rule-denial markers" "1" "$MARKER_RULE"
RULE_RE_RC=0
RULE_RE=$(grep -cF "extractAll(b.req_body, '[(]([a-z][a-z0-9-]+)[)] [(]2[0-9]{3}-[0-9]{2}-[0-9]{2}T')" "$CRUNCH" ) || { RULE_RE_RC=$?; RULE_RE="0"; }
assert_eq "crunch extracts rule ids anchored before the ISO timestamp" "1" "$RULE_RE"

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
