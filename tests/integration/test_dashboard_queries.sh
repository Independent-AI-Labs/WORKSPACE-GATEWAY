#!/bin/bash
set -euo pipefail

# Dashboard Query Integration Tests
# Extracts queries from Grafana dashboard JSON, substitutes placeholders,
# hits ClickHouse (:8123) and Prometheus (:9092), verifies valid data.
# SQL: tests/integration/queries/*.sql (13 ClickHouse queries)
# YAML: tests/integration/queries/prometheus.yaml (12 PromQL expressions)
# Placeholders: __FROM__, __TO__, __API_KEYS__, __MODELS__, __API_KEY_REGEX__

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
QUERIES_DIR="$SCRIPT_DIR/queries"

CH_URL="http://localhost:8123"
PROM_URL="http://localhost:9092"
GATEWAY_URL="http://localhost:9080"
DASHBOARD_FILE="$REPO_ROOT/conf/grafana/dashboards/gateway-overview.json"

pass=0
fail=0
skip=0

# ── Helpers ─────────────────────────────────────────────────────────────────

record_pass() {
    echo "[PASS] $1"
    pass=$((pass + 1))
}

record_fail() {
    echo "[FAIL] $1"
    fail=$((fail + 1))
}

record_skip() {
    echo "[SKIP] $1"
    skip=$((skip + 1))
}

# ── Skip if stack not running ───────────────────────────────────────────────

curl_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    "$GATEWAY_URL/" 2>/dev/null || echo "000")
if [ "$curl_code" = "000" ]; then
    echo "[SKIP] APISIX not reachable, skipping dashboard query tests"
    exit 0
fi

ch_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    "$CH_URL/?query=SELECT%201" 2>/dev/null || echo "000")
if [ "$ch_code" != "200" ]; then
    echo "[SKIP] ClickHouse not reachable on :8123, skipping dashboard query tests"
    exit 0
fi

prom_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    "$PROM_URL/-/healthy" 2>/dev/null || echo "000")
if [ "$prom_code" != "200" ]; then
    echo "[SKIP] Prometheus not reachable on :9092, skipping dashboard query tests"
    exit 0
fi

echo "=== Dashboard Query Integration Tests ==="
echo ""

# ── Compute time range (last 24h) ───────────────────────────────────────────

FROM_TS=$(date -d '24 hours ago' '+%Y-%m-%d %H:%M:%S')
TO_TS=$(date '+%Y-%m-%d %H:%M:%S')

echo "[INFO] Time range: $FROM_TS → $TO_TS"
echo ""

# ── Fetch all key hashes from ClickHouse ────────────────────────────────────

ALL_KEYS=$(curl -sf "$CH_URL/" --data-binary "SELECT DISTINCT coalesce(nullIf(key_id,''), nullIf(api_key_id,''), 'unknown') AS k FROM llm_gateway.usage_log ORDER BY k FORMAT TabSeparated" 2>/dev/null || echo "")
if [ -z "$ALL_KEYS" ]; then
    ALL_KEYS=$(curl -sf "$CH_URL/" --data-binary "SELECT DISTINCT coalesce(nullIf(key_id,''), nullIf(api_key_id,''), 'unknown') AS k FROM llm_gateway.request_log ORDER BY k FORMAT TabSeparated" 2>/dev/null || echo "")
fi

if [ -z "$ALL_KEYS" ]; then
    echo "[WARN] No key hashes found in ClickHouse; using wildcard"
    ALL_KEYS="unknown"
fi

# Build quoted list for ClickHouse IN clause (pure bash + sed)
CH_KEY_LIST=$(echo "$ALL_KEYS" | grep '.' | sed "s/^/'/; s/$/'/" | paste -sd, -)
if [ -z "$CH_KEY_LIST" ]; then
    CH_KEY_LIST="'unknown'"
fi

# Build regex for Prometheus: key1|key2|key3
PROM_KEY_REGEX=$(echo "$ALL_KEYS" | grep '.' | paste -sd '|' -)
if [ -z "$PROM_KEY_REGEX" ]; then
    PROM_KEY_REGEX=".*"
fi

KEY_COUNT=$(echo "$ALL_KEYS" | grep -c '.' || true)
echo "[INFO] Key hashes: $KEY_COUNT keys found"
echo "[INFO] Prom regex: $PROM_KEY_REGEX"
echo ""

# ── Fetch all models from ClickHouse (UNION of both tables) ─────────────────

ALL_MODELS=$(curl -sf "$CH_URL/" --data-binary "SELECT DISTINCT model FROM (SELECT model FROM llm_gateway.request_log WHERE model != '' UNION ALL SELECT model FROM llm_gateway.usage_log WHERE model != '') ORDER BY model FORMAT TabSeparated" 2>/dev/null || echo "")

if [ -z "$ALL_MODELS" ]; then
    echo "[WARN] No models found in ClickHouse; using wildcard"
    ALL_MODELS="unknown"
fi

CH_MODEL_LIST=$(echo "$ALL_MODELS" | grep '.' | sed "s/^/'/; s/$/'/" | paste -sd, -)
if [ -z "$CH_MODEL_LIST" ]; then
    CH_MODEL_LIST="'unknown'"
fi

MODEL_COUNT=$(echo "$ALL_MODELS" | grep -c '.' || true)
echo "[INFO] Models: $MODEL_COUNT found"
echo ""

# ── SQL substitution helper (pure sed) ──────────────────────────────────────

substitute_sql() {
    local sql_file="$1"
    local from_ts="$2"
    local to_ts="$3"
    local key_list="$4"
    local model_list="$5"

    sed \
        -e "s|__FROM__|'$from_ts'|g" \
        -e "s|__TO__|'$to_ts'|g" \
        -e "s|__API_KEYS__|$key_list|g" \
        -e "s|__MODELS__|$model_list|g" \
        "$sql_file"
}

# ── URL-encode helper (jq @uri) ─────────────────────────────────────────────

url_encode() {
    printf '%s' "$1" | jq -sRr @uri
}

# ── Run ClickHouse queries (.sql files) ─────────────────────────────────────

echo "--- ClickHouse Panel Queries (All keys, All models) ---"
echo ""

run_ch_query() {
    local sql_file="$1"
    local desc="$2"
    local min_rows="${3:-1}"

    if [ ! -f "$QUERIES_DIR/$sql_file" ]; then
        record_fail "$desc: SQL file $sql_file not found"
        return
    fi

    local sql
    sql=$(substitute_sql "$QUERIES_DIR/$sql_file" "$FROM_TS" "$TO_TS" "$CH_KEY_LIST" "$CH_MODEL_LIST")

    if [ -z "$sql" ]; then
        record_fail "$desc: SQL substitution failed"
        return
    fi

    # Execute via ClickHouse HTTP interface (POST with data-binary)
    local body http_code
    body=$(curl -sf -w "\n%{http_code}" --max-time 30 \
        -X POST "$CH_URL/" \
        --data-binary "$sql" 2>/dev/null || echo "CURL_ERROR
000")

    http_code=$(echo "$body" | tail -1)
    body=$(echo "$body" | sed '$d')

    if [ "$http_code" = "000" ] || [ "$http_code" = "CURL_ERROR" ]; then
        record_fail "$desc: curl failed"
        return
    fi

    if [ "$http_code" != "200" ]; then
        record_fail "$desc: HTTP $http_code - ${body:0120}"
        return
    fi

    # Count non-empty lines
    local row_count
    row_count=$(printf '%s\n' "$body" | grep -c '.' || true)

    if [ "$row_count" -lt "$min_rows" ]; then
        record_fail "$desc: expected >= $min_rows rows, got $row_count"
        return
    fi

    record_pass "$desc: $row_count rows returned"
}

# p3: Token Usage by Category (5 stat tiles)
run_ch_query "p3_total.sql"    "p3-A Total tokens + cost"     1
run_ch_query "p3_input.sql"    "p3-B Input tokens + cost"     1
run_ch_query "p3_cached.sql"   "p3-C Cached tokens + cost"    1
run_ch_query "p3_output.sql"   "p3-D Output tokens + cost"    1
run_ch_query "p3_reasoning.sql" "p3-E Reasoning tokens + cost" 1

# p8: Model Distribution
run_ch_query "p8_model_dist.sql"    "p8-A Model distribution"     1

# p10: Avg Latency by Model
run_ch_query "p10_avg_latency.sql"  "p10-A Avg latency by model"  0

# p13: Stream Abort Rate
run_ch_query "p13_abort_client.sql"    "p13-A Client abort rate"    0
run_ch_query "p13_abort_provider.sql"  "p13-B Provider abort rate"  0

# p14: Stream Status
run_ch_query "p14_completed.sql"        "p14-A Stream completed"        0
run_ch_query "p14_client_aborted.sql"   "p14-B Stream client aborted"   0
run_ch_query "p14_provider_aborted.sql" "p14-C Stream provider aborted" 0

# p15: Cost Over Time
run_ch_query "p15_cost_over_time.sql"   "p15-A Cost over time by model" 0

echo ""

# ── Verify p3 format: should match "NN Mil ($X.XX)" or "NN K ($X.XX)" ──────

echo "--- p3 Value Format Verification ---"
echo ""

verify_p3_format() {
    local sql_file="$1"
    local desc="$2"

    local sql
    sql=$(substitute_sql "$QUERIES_DIR/$sql_file" "$FROM_TS" "$TO_TS" "$CH_KEY_LIST" "$CH_MODEL_LIST")

    local result
    result=$(curl -sf --max-time 30 \
        -X POST "$CH_URL/" \
        --data-binary "$sql" 2>/dev/null || echo "")

    if [ -z "$result" ]; then
        record_fail "$desc: empty result"
        return
    fi

    # Format should be: "NN Mil ($X.XX)" or "NN K ($X.XX)" or "NN ($X.XX)"
    if echo "$result" | grep -qP '^\d+ (Mil|K) \(\$\d+\.\d+\)$'; then
        record_pass "$desc: format valid - $(echo "$result" | head -1)"
    elif echo "$result" | grep -qP '^\d+ \(\$\d+\.\d+\)$'; then
        record_pass "$desc: format valid (small number) - $(echo "$result" | head -1)"
    elif echo "$result" | grep -qP '^\d+ \(\$\d+\)$'; then
        record_pass "$desc: format valid (integer cost) - $(echo "$result" | head -1)"
    else
        record_fail "$desc: format invalid - $(echo "$result" | head -1)"
    fi
}

verify_p3_format "p3_total.sql"    "p3-A format"
verify_p3_format "p3_input.sql"    "p3-B format"
verify_p3_format "p3_cached.sql"   "p3-C format"
verify_p3_format "p3_output.sql"   "p3-D format"
verify_p3_format "p3_reasoning.sql" "p3-E format"

echo ""

# ── p3 Output Correctness: total = input + cached + output + reasoning ──────

echo "--- p3 Token Consistency (total = input + cached + output + reasoning) ---"
echo ""

# Query raw (unformatted) token counts in a single round-trip for consistency check
P3_RAW_SQL=$(substitute_sql "$QUERIES_DIR/p3_raw_tokens.sql" "$FROM_TS" "$TO_TS" "$CH_KEY_LIST" "$CH_MODEL_LIST")
P3_RAW_RESULT=$(curl -sf --max-time 30 -X POST "$CH_URL/" --data-binary "$P3_RAW_SQL" 2>/dev/null || echo "")
# ClickHouse TabSeparated: total\tinput\tcached\toutput\treasoning
P3_TOTAL_TOK=$(echo "$P3_RAW_RESULT" | head -1 | cut -f1)
P3_INPUT_TOK=$(echo "$P3_RAW_RESULT" | head -1 | cut -f2)
P3_CACHED_TOK=$(echo "$P3_RAW_RESULT" | head -1 | cut -f3)
P3_OUTPUT_TOK=$(echo "$P3_RAW_RESULT" | head -1 | cut -f4)
P3_REASONING_TOK=$(echo "$P3_RAW_RESULT" | head -1 | cut -f5)
# Guard against empty/missing values
P3_TOTAL_TOK=${P3_TOTAL_TOK:-0}
P3_INPUT_TOK=${P3_INPUT_TOK:-0}
P3_CACHED_TOK=${P3_CACHED_TOK:-0}
P3_OUTPUT_TOK=${P3_OUTPUT_TOK:-0}
P3_REASONING_TOK=${P3_REASONING_TOK:-0}

P3_SUM=$((P3_INPUT_TOK + P3_CACHED_TOK + P3_OUTPUT_TOK + P3_REASONING_TOK))

if [ "$P3_TOTAL_TOK" -eq "$P3_SUM" ]; then
    record_pass "p3 token consistency: total ($P3_TOTAL_TOK) = input ($P3_INPUT_TOK) + cached ($P3_CACHED_TOK) + output ($P3_OUTPUT_TOK) + reasoning ($P3_REASONING_TOK)"
else
    record_fail "p3 token consistency: total ($P3_TOTAL_TOK) != sum ($P3_SUM) = input ($P3_INPUT_TOK) + cached ($P3_CACHED_TOK) + output ($P3_OUTPUT_TOK) + reasoning ($P3_REASONING_TOK)"
fi

echo ""

# ── Run Prometheus queries ──────────────────────────────────────────────────

echo "--- Prometheus Panel Queries (All keys) ---"
echo ""

run_prom_query() {
    local expr="$1"
    local desc="$2"

    # URL-encode the expression using jq @uri
    local encoded_expr
    encoded_expr=$(url_encode "$expr")

    if [ -z "$encoded_expr" ]; then
        record_fail "$desc: failed to URL-encode expression"
        return
    fi

    local response
    response=$(curl -sf --max-time 15 \
        "$PROM_URL/api/v1/query?query=$encoded_expr" 2>/dev/null || echo "")

    if [ -z "$response" ]; then
        record_fail "$desc: empty response from Prometheus"
        return
    fi

    # Parse response using jq
    local status result_count
    status=$(echo "$response" | jq -r '.status // "unknown"' 2>/dev/null || echo "parse_error")
    result_count=$(echo "$response" | jq -r '.data.result | length' 2>/dev/null || echo "0")

    if [ "$status" != "success" ]; then
        record_fail "$desc: Prom status=$status"
        return
    fi

    if [ "$result_count" = "0" ]; then
        record_fail "$desc: no result data"
        return
    fi

    record_pass "$desc: $result_count results"
}

# Parse prometheus.yaml via containerized Lua YAML parser, run each expression
# Source the shared YAML helper
source "$REPO_ROOT/tests/config/yaml_helpers.sh"

PROM_YAML_JSON=$(yaml_to_json "$QUERIES_DIR/prometheus.yaml")

if [ -z "$PROM_YAML_JSON" ]; then
    record_fail "Failed to parse prometheus.yaml"
else
    echo "$PROM_YAML_JSON" | jq -r --arg regex "$PROM_KEY_REGEX" \
        '.[] | [.panel, .refId, .title, (.expr | gsub("__API_KEY_REGEX__"; $regex))] | @tsv' \
    | while IFS=$'\t' read -r panel ref title expr; do
        run_prom_query "$expr" "p${panel}-${ref} ${title}"
    done
fi

echo ""

# ── Single key filter test (pick first key hash) ────────────────────────────

echo "--- Single Key Filter Tests ---"
echo ""

SINGLE_KEY=$(echo "$ALL_KEYS" | head -1)
if [ -n "$SINGLE_KEY" ] && [ "$SINGLE_KEY" != "unknown" ]; then
    SINGLE_KEY_LIST="'$SINGLE_KEY'"
    SINGLE_KEY_REGEX="$SINGLE_KEY"

    echo "[INFO] Testing with single key: $SINGLE_KEY"
    echo ""

    # p3 total with single key
    sql=$(substitute_sql "$QUERIES_DIR/p3_total.sql" "$FROM_TS" "$TO_TS" "$SINGLE_KEY_LIST" "$CH_MODEL_LIST")
    result=$(curl -sf --max-time 30 -X POST "$CH_URL/" --data-binary "$sql" 2>/dev/null || echo "")

    if [ -n "$result" ]; then
        record_pass "p3-A single key filter: $(echo "$result" | head -1)"
    else
        record_fail "p3-A single key filter: empty result"
    fi

    # p8 model dist with single key (may return 0 rows - that's OK, just verify no error)
    sql=$(substitute_sql "$QUERIES_DIR/p8_model_dist.sql" "$FROM_TS" "$TO_TS" "$SINGLE_KEY_LIST" "$CH_MODEL_LIST")
    http_result=$(curl -sf -w "\n%{http_code}" --max-time 30 -X POST "$CH_URL/" --data-binary "$sql" 2>/dev/null || echo "
000")
    http_code=$(echo "$http_result" | tail -1)
    if [ "$http_code" = "200" ]; then
        record_pass "p8-A single key filter: HTTP 200 (no SQL error)"
    else
        record_fail "p8-A single key filter: HTTP $http_code"
    fi

    # p1 Total Requests with single key (Prometheus)
    p1_expr="sum(apisix_http_status{key_hash=~\"$SINGLE_KEY_REGEX\"})"
    encoded=$(url_encode "$p1_expr")
    response=$(curl -sf --max-time 15 "$PROM_URL/api/v1/query?query=$encoded" 2>/dev/null || echo "")

    if [ -n "$response" ]; then
        status=$(echo "$response" | jq -r '.status // "?"' 2>/dev/null || echo "?")
        if [ "$status" = "success" ]; then
            record_pass "p1-A single key filter (Prom): success"
        else
            record_fail "p1-A single key filter (Prom): status=$status"
        fi
    else
        record_fail "p1-A single key filter (Prom): empty response"
    fi
else
    record_skip "Single key filter tests (no keys available)"
fi

echo ""

# ── Single model filter test ────────────────────────────────────────────────

echo "--- Single Model Filter Tests ---"
echo ""

SINGLE_MODEL=$(echo "$ALL_MODELS" | head -1)
if [ -n "$SINGLE_MODEL" ] && [ "$SINGLE_MODEL" != "unknown" ]; then
    SINGLE_MODEL_LIST="'$SINGLE_MODEL'"

    echo "[INFO] Testing with single model: $SINGLE_MODEL"
    echo ""

    # p3 total with single model
    sql=$(substitute_sql "$QUERIES_DIR/p3_total.sql" "$FROM_TS" "$TO_TS" "$CH_KEY_LIST" "$SINGLE_MODEL_LIST")
    result=$(curl -sf --max-time 30 -X POST "$CH_URL/" --data-binary "$sql" 2>/dev/null || echo "")

    if [ -n "$result" ]; then
        record_pass "p3-A single model filter: $(echo "$result" | head -1)"
    else
        record_fail "p3-A single model filter: empty result"
    fi

    # p15 cost over time with single model (may return 0 rows - OK)
    sql=$(substitute_sql "$QUERIES_DIR/p15_cost_over_time.sql" "$FROM_TS" "$TO_TS" "$CH_KEY_LIST" "$SINGLE_MODEL_LIST")
    http_result=$(curl -sf -w "\n%{http_code}" --max-time 30 -X POST "$CH_URL/" --data-binary "$sql" 2>/dev/null || echo "
000")
    http_code=$(echo "$http_result" | tail -1)
    if [ "$http_code" = "200" ]; then
        record_pass "p15-A single model filter: HTTP 200 (no SQL error)"
    else
        record_fail "p15-A single model filter: HTTP $http_code"
    fi
else
    record_skip "Single model filter tests (no models available)"
fi

echo ""

# ── Verify no $__conditionalAll remains in dashboard ────────────────────────

echo "--- Dashboard Macro Verification ---"
echo ""

COND_ALL_COUNT=$(jq '[.panels[].targets[] | (.rawSql // .expr // "") | select(. != null) | select(test("\\$\\$__conditionalAll"))] | length' "$DASHBOARD_FILE" 2>/dev/null || echo "error")

if [ "$COND_ALL_COUNT" = "0" ]; then
    record_pass "No \$__conditionalAll macros in dashboard"
else
    record_fail "Dashboard still has $COND_ALL_COUNT \$__conditionalAll macros"
fi

# Verify api_key variable has no allValue
API_KEY_ALLVALUE=$(jq -r \
    '[.templating.list[] | select(.name == "api_key")] | if length == 0 then "error" else (.[0].allValue | if . == null or . == "" then "None" else . end) end' \
    "$DASHBOARD_FILE" 2>/dev/null || echo "error")

if [ "$API_KEY_ALLVALUE" = "None" ]; then
    record_pass "api_key variable has no allValue"
else
    record_fail "api_key variable still has allValue=$API_KEY_ALLVALUE"
fi

# Verify model variable queries both tables
MODEL_QUERY=$(jq -r \
    '[.templating.list[] | select(.name == "model")] | if length == 0 then "error" else (.[0].query | ascii_upcase | if test("UNION") then "union" else "single" end) end' \
    "$DASHBOARD_FILE" 2>/dev/null || echo "error")

if [ "$MODEL_QUERY" = "union" ]; then
    record_pass "model variable queries both request_log and usage_log"
else
    record_fail "model variable does not UNION both tables"
fi

echo ""

# ── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "Dashboard query tests: $pass passed, $fail failed, $skip skipped"
if [ "$fail" -gt 0 ]; then
    exit 1
fi
exit 0
