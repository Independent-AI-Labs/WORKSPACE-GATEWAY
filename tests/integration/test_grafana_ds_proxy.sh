#!/bin/bash
set -euo pipefail

# Grafana Datasource Proxy Tests
# Verifies that dashboard panel queries return correct data through
# Grafana's datasource proxy API (not direct ClickHouse).
# This catches macro expansion issues, datasource misconfig, and
# format/queryType problems that direct ClickHouse tests miss.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DASHBOARD_FILE="$REPO_ROOT/conf/grafana/dashboards/gateway-overview.json"

GRAFANA_URL="http://localhost:3030"
GRAFANA_AUTH="admin:admin"
CH_UID="clickhouse"
PROM_UID="prometheus"

pass=0; fail=0; skip=0
rp() { echo "[PASS] $1"; pass=$((pass+1)); }
rf() { echo "[FAIL] $1"; fail=$((fail+1)); }
rs() { echo "[SKIP] $1"; skip=$((skip+1)); }

# Skip if Grafana not running
gf_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$GRAFANA_URL/api/health" 2>/dev/null || echo "000")
if [ "$gf_code" != "200" ]; then
    echo "[SKIP] Grafana not reachable (HTTP $gf_code)"
    exit 0
fi

echo "=== Grafana Datasource Proxy Tests ==="
echo ""

# Extract query from dashboard JSON by panel title
get_panel_query() {
    local title="$1"
    jq -r --arg t "$title" \
        '.panels[] | select(.title == $t) | .targets[0].rawSql // .targets[0].expr // empty' \
        "$DASHBOARD_FILE"
}

# Extract datasource UID from dashboard JSON by panel title
get_panel_ds() {
    local title="$1"
    jq -r --arg t "$title" \
        '.panels[] | select(.title == $t) | .datasource.uid' \
        "$DASHBOARD_FILE"
}

# Extract format from panel target
get_panel_format() {
    local title="$1"
    jq -r --arg t "$title" \
        '.panels[] | select(.title == $t) | .targets[0].format // "none"' \
        "$DASHBOARD_FILE"
}

# Query Grafana datasource proxy
# Args: $1=datasource_uid, $2=raw_sql, $3=format, $4=queryType
# Substitutes Grafana macros: $__timeFilter, ${api_key:singlequote}, ${model:singlequote}
ds_query() {
    local ds_uid="$1"; local sql="$2"; local fmt="$3"; local qt="$4"

    # Step 1: Replace $__timeFilter(col) with time range using sed (no quotes in replacement)
    sql=$(printf '%s' "$sql" | sed \
        -e 's|\$__timeFilter(r\.timestamp)|r.timestamp >= now() - INTERVAL 24 HOUR|g' \
        -e 's|\$__timeFilter(timestamp)|timestamp >= now() - INTERVAL 24 HOUR|g')

    # Step 2: Replace ${api_key:singlequote} and ${model:singlequote} with placeholder tokens
    sql=$(printf '%s' "$sql" | sed \
        -e 's|\${api_key:singlequote}|APIKEYPLACEHOLDER|g' \
        -e 's|\${model:singlequote}|MODELPLACEHOLDER|g')

    # Step 3: Replace placeholders with actual subqueries using bash (handles quotes)
    local all_keys_sub="(SELECT DISTINCT coalesce(nullIf(key_id,''), nullIf(api_key_id,''), 'unknown') FROM llm_gateway.request_log)"
    local all_models_sub="(SELECT DISTINCT model FROM llm_gateway.usage_log WHERE model != '')"
    sql="${sql//APIKEYPLACEHOLDER/$all_keys_sub}"
    sql="${sql//MODELPLACEHOLDER/$all_models_sub}"

    local payload
    payload=$(jq -n \
        --arg uid "$ds_uid" \
        --arg sql "$sql" \
        --arg fmt "$fmt" \
        --arg qt "$qt" \
        '{
            queries: [{
                datasource: {uid: $uid, type: "grafana-clickhouse-datasource"},
                format: $fmt,
                queryType: $qt,
                rawSql: $sql,
                refId: "A"
            }],
            range: {from: "now-24h", to: "now"}
        }')
    curl -sf --max-time 30 -X POST "$GRAFANA_URL/api/ds/query" \
        -u "$GRAFANA_AUTH" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null || echo ""
}

# Extract values array from ds_query response
# $1=response_json, $2=field_index (0-based)
ds_values() {
    echo "$1" | jq -r ".results.A.frames[0].data.values[$2] // []" 2>/dev/null
}

ds_value_count() {
    echo "$1" | jq -r '.results.A.frames[0].data.values[0] | length' 2>/dev/null
}

# =====================================================================
# T1: Total Requests (p1) - ClickHouse, format:table
# =====================================================================
echo "--- T1: Total Requests (ClickHouse) ---"
T1_QUERY=$(get_panel_query "Total Requests")
T1_DS=$(get_panel_ds "Total Requests")
T1_FMT=$(get_panel_format "Total Requests")

[ "$T1_DS" = "$CH_UID" ] && rp "T1: datasource=clickhouse" || rf "T1: datasource=$T1_DS (expected clickhouse)"
[ "$T1_FMT" = "table" ] && rp "T1: format=table" || rf "T1: format=$T1_FMT (expected table)"

T1_RESP=$(ds_query "$T1_DS" "$T1_QUERY" "table" "table")
# Single-column query: values[0][0] is the count
T1_VAL=$(echo "$T1_RESP" | jq -r '.results.A.frames[0].data.values[0][0] // "null"' 2>/dev/null)
if [ "$T1_VAL" != "null" ] && [ "$T1_VAL" -gt 100 ] 2>/dev/null; then
    rp "T1: total_requests=$T1_VAL (>100, not reset counter)"
else
    rf "T1: total_requests=$T1_VAL (expected >100)"
fi
echo ""

# =====================================================================
# T2: Error Rate (p4) - must count 4xx+5xx, not just 5xx
# =====================================================================
echo "--- T2: Error Rate (4xx+5xx, not just 5xx) ---"
T2_QUERY=$(get_panel_query "Error Rate %")
T2_DS=$(get_panel_ds "Error Rate %")

[ "$T2_DS" = "$CH_UID" ] && rp "T2: datasource=clickhouse" || rf "T2: datasource=$T2_DS (expected clickhouse)"

# Verify query counts 4xx (status >= 400, not >= 500)
echo "$T2_QUERY" | grep -q "status >= 400" && rp "T2: counts 4xx+5xx (status >= 400)" || rf "T2: only counts 5xx (missing status >= 400)"
echo "$T2_QUERY" | grep -q "status >= 500" && rf "T2: still has old status >= 500" || rp "T2: no old status >= 500"

T2_RESP=$(ds_query "$T2_DS" "$T2_QUERY" "table" "table")
# Single-column query: values[0][0] is the error rate
T2_VAL=$(echo "$T2_RESP" | jq -r '.results.A.frames[0].data.values[0][0] // "null"' 2>/dev/null)
# Error rate should be > 0.20% (old 5xx-only rate) since we now count 4xx
if [ "$T2_VAL" != "null" ]; then
    T2_GT=$(awk "BEGIN{print ($T2_VAL > 0.20) ? 1 : 0}" 2>/dev/null)
    [ "$T2_GT" = "1" ] && rp "T2: error_rate=$T2_VAL% (>0.20%, includes 4xx)" || rf "T2: error_rate=$T2_VAL% (should be >0.20%)"
else
    rf "T2: no response from datasource proxy"
fi
echo ""

# =====================================================================
# T3: Status Code Breakdown (p7) - piechart, 7 status codes, not "2"
# =====================================================================
echo "--- T3: Status Code Breakdown (piechart, reduceOptions.values=true) ---"
T3_QUERY=$(get_panel_query "Status Code Breakdown")
T3_DS=$(get_panel_ds "Status Code Breakdown")
T3_FMT=$(get_panel_format "Status Code Breakdown")
T3_REDUCE=$(jq -r '.panels[] | select(.title == "Status Code Breakdown") | .options.reduceOptions.values // false' "$DASHBOARD_FILE")

[ "$T3_DS" = "$CH_UID" ] && rp "T3: datasource=clickhouse" || rf "T3: datasource=$T3_DS (expected clickhouse)"
[ "$T3_FMT" = "table" ] && rp "T3: format=table" || rf "T3: format=$T3_FMT (expected table)"
[ "$T3_REDUCE" = "true" ] && rp "T3: reduceOptions.values=true" || rf "T3: reduceOptions.values=$T3_REDUCE (expected true)"

T3_RESP=$(ds_query "$T3_DS" "$T3_QUERY" "table" "table")
T3_COUNT=$(ds_value_count "$T3_RESP")
# Should return 7 status codes (200, 401, 404, 429, 499, 503, 504)
# NOT 1 or 2 (which would mean the piechart is reducing all rows to a single value)
if [ "$T3_COUNT" -ge 5 ] 2>/dev/null; then
    rp "T3: $T3_COUNT status codes returned (>=5, not reduced to single value)"
else
    rf "T3: only $T3_COUNT values returned (piechart would show 'count 100%' bug)"
fi

# Verify status codes include 4xx (not just 200 and 5xx)
T3_CODES=$(echo "$T3_RESP" | jq -r '.results.A.frames[0].data.values[0][]' 2>/dev/null | paste -sd, -)
echo "$T3_CODES" | grep -qE "40[0-9]|41[0-9]|42[0-9]|43[0-9]|44[0-9]|45[0-9]|46[0-9]|47[0-9]|48[0-9]|49[0-9]" \
    && rp "T3: 4xx codes present ($T3_CODES)" \
    || rf "T3: no 4xx codes in ($T3_CODES)"
echo ""

# =====================================================================
# T4: Model Distribution (id=8) - ASOF JOIN, ~1900 total not 23
# =====================================================================
echo "--- T4: Model Distribution (ASOF JOIN usage_log) ---"
T4_QUERY=$(get_panel_query "Model Distribution")
T4_DS=$(get_panel_ds "Model Distribution")

[ "$T4_DS" = "$CH_UID" ] && rp "T4: datasource=clickhouse" || rf "T4: datasource=$T4_DS (expected clickhouse)"

# Verify query uses ASOF LEFT JOIN (not request_log.model directly)
echo "$T4_QUERY" | grep -qi "ASOF LEFT JOIN" && rp "T4: uses ASOF LEFT JOIN" || rf "T4: no ASOF LEFT JOIN (still querying request_log.model)"
echo "$T4_QUERY" | grep -q "u.model" && rp "T4: selects u.model from usage_log" || rf "T4: does not select u.model"

T4_RESP=$(ds_query "$T4_DS" "$T4_QUERY" "table" "table")
T4_COUNT=$(ds_value_count "$T4_RESP")
# Sum all model counts
T4_SUM=$(echo "$T4_RESP" | jq -r '.results.A.frames[0].data.values[1][]' 2>/dev/null | awk '{s+=$1} END{print s+0}')
# Should be ~1900 (ASOF JOIN matches usage_log), NOT 23 (request_log.model only)
if [ "$T4_SUM" -gt 100 ] 2>/dev/null; then
    rp "T4: model_dist total=$T4_SUM (>100, ASOF JOIN working)"
else
    rf "T4: model_dist total=$T4_SUM (expected >100, got small count - ASOF JOIN not working)"
fi
echo ""

# =====================================================================
# T5: Avg Latency by Model (id=10) - ASOF JOIN, 4+ models
# =====================================================================
echo "--- T5: Avg Latency by Model (ASOF JOIN usage_log) ---"
T5_QUERY=$(get_panel_query "Avg Latency by Model (seconds)")
T5_DS=$(get_panel_ds "Avg Latency by Model (seconds)")

[ "$T5_DS" = "$CH_UID" ] && rp "T5: datasource=clickhouse" || rf "T5: datasource=$T5_DS (expected clickhouse)"

# Verify query uses ASOF LEFT JOIN
echo "$T5_QUERY" | grep -qi "ASOF LEFT JOIN" && rp "T5: uses ASOF LEFT JOIN" || rf "T5: no ASOF LEFT JOIN"
echo "$T5_QUERY" | grep -q "u.model" && rp "T5: selects u.model from usage_log" || rf "T5: does not select u.model"
echo "$T5_QUERY" | grep -q "r.upstream_response_time_s" && rp "T5: latency from request_log" || rf "T5: missing r.upstream_response_time_s"

T5_RESP=$(ds_query "$T5_DS" "$T5_QUERY" "table" "table")
T5_COUNT=$(ds_value_count "$T5_RESP")
# Should return 3+ models (was only showing small subset before)
if [ "$T5_COUNT" -ge 3 ] 2>/dev/null; then
    rp "T5: $T5_COUNT models with latency data (>=3)"
else
    rf "T5: only $T5_COUNT models (expected >=3)"
fi

# Verify latency values are reasonable (0.001 to 300 seconds)
T5_LATS=$(echo "$T5_RESP" | jq -r '.results.A.frames[0].data.values[1][]' 2>/dev/null)
T5_BAD=0
for lat in $T5_LATS; do
    T5_OK=$(awk "BEGIN{print ($lat >= 0.001 && $lat <= 300) ? 1 : 0}" 2>/dev/null || echo "0")
    [ "$T5_OK" = "0" ] && T5_BAD=$((T5_BAD+1))
done
[ "$T5_BAD" = "0" ] && rp "T5: all latencies in [0.001, 300]s" || rf "T5: $T5_BAD latencies out of range"
echo ""

# =====================================================================
# Summary
# =====================================================================
echo ""
echo "Grafana DS proxy tests: $pass passed, $fail failed, $skip skipped"
[ "$fail" -gt 0 ] && exit 1 || exit 0
