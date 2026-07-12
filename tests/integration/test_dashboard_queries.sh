#!/bin/bash
set -euo pipefail

# Dashboard Query Integration Tests (Q1-Q16)
# ALL queries extracted from the dashboard JSON (single source of truth) via jq.
# No .sql or .yaml files -- no duplicated queries.
# Macros substituted: $__timeFilter, ${api_key:singlequote}, ${model:singlequote}, $api_key

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DASH_DIR="$REPO_ROOT/conf/grafana/dashboards"
COST_USAGE_FILE="$DASH_DIR/gateway-cost-usage.json"
OPS_HEALTH_FILE="$DASH_DIR/gateway-ops-health.json"
LEADERBOARD_FILE="$DASH_DIR/gateway-cost-leaderboard.json"
ALL_DASHBOARDS=("$COST_USAGE_FILE" "$OPS_HEALTH_FILE" "$LEADERBOARD_FILE")

CH_URL="http://localhost:8123"
PROM_URL="http://localhost:9092"
GATEWAY_URL="http://localhost:9080"

pass=0; fail=0; skip=0
rp() { echo "[PASS] $1"; pass=$((pass+1)); }
rf() { echo "[FAIL] $1"; fail=$((fail+1)); }
rs() { echo "[SKIP] $1"; skip=$((skip+1)); }

# ── Skip if stack not running ──────────────────────────────────────────
curl_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$GATEWAY_URL/" || echo "000")
[ "$curl_code" = "000" ] && { echo "[SKIP] APISIX not reachable"; exit 0; }
ch_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$CH_URL/?query=SELECT%201" || echo "000")
[ "$ch_code" != "200" ] && { echo "[SKIP] ClickHouse not reachable"; exit 0; }
prom_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$PROM_URL/-/healthy" || echo "000")
[ "$prom_code" != "200" ] && { echo "[SKIP] Prometheus not reachable"; exit 0; }

echo "=== Dashboard Query Integration Tests (extracted from JSON) ==="
echo ""

# ── Time range (last 7d) ───────────────────────────────────────────────
FROM_TS=$(date -d '7 days ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || \
    date -u -d "@$(($(date +%s)-604800))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || \
    date -u -r "$(( $(date +%s) - 604800 ))" '+%Y-%m-%d %H:%M:%S')
TO_TS=$(date '+%Y-%m-%d %H:%M:%S')
echo "[INFO] Time range: $FROM_TS to $TO_TS"

# ── Fetch all key hashes and models from ClickHouse ────────────────────
ALL_KEYS=$(curl -sf "$CH_URL/" --data-binary \
    "SELECT DISTINCT coalesce(nullIf(key_id,''), nullIf(api_key_id,''), 'unknown') AS k FROM llm_gateway.usage_log ORDER BY k FORMAT TabSeparated" \
    || echo "")
[ -z "$ALL_KEYS" ] && ALL_KEYS=$(curl -sf "$CH_URL/" --data-binary \
    "SELECT DISTINCT coalesce(nullIf(key_id,''), nullIf(api_key_id,''), 'unknown') AS k FROM llm_gateway.request_log ORDER BY k FORMAT TabSeparated" \
    || echo "")
[ -z "$ALL_KEYS" ] && ALL_KEYS="unknown"
CH_KEY_LIST=$(echo "$ALL_KEYS" | grep '.' | sed "s/^/'/; s/$/'/" | paste -sd, -)
[ -z "$CH_KEY_LIST" ] && CH_KEY_LIST="'unknown'"
PROM_KEY_REGEX=$(echo "$ALL_KEYS" | grep '.' | paste -sd '|' -)
[ -z "$PROM_KEY_REGEX" ] && PROM_KEY_REGEX=".*"
echo "[INFO] Keys: $(echo "$ALL_KEYS" | grep -c '.' || true)"

ALL_MODELS=$(curl -sf "$CH_URL/" --data-binary \
    "SELECT DISTINCT model FROM (SELECT model FROM llm_gateway.request_log WHERE model != '' UNION ALL SELECT model FROM llm_gateway.usage_log WHERE model != '') ORDER BY model FORMAT TabSeparated" \
    || echo "")
[ -z "$ALL_MODELS" ] && ALL_MODELS="unknown"
CH_MODEL_LIST=$(echo "$ALL_MODELS" | grep '.' | sed "s/^/'/; s/$/'/" | paste -sd, -)
[ -z "$CH_MODEL_LIST" ] && CH_MODEL_LIST="'unknown'"
echo "[INFO] Models: $(echo "$ALL_MODELS" | grep -c '.' || true)"
echo ""

# ── Query extraction helpers (jq → dashboard JSON, all 3 files) ────────

# Find which dashboard file contains a given panel id (echo path, empty if none)
find_panel_file() {
    local pid="$1"
    for df in "${ALL_DASHBOARDS[@]}"; do
        local n
        n=$(jq --arg pid "$pid" '[.panels[] | select(.id == ($pid | tonumber))] | length' "$df" 2>/dev/null || echo 0)
        [ "$n" -gt 0 ] && { printf '%s' "$df"; return; }
    done
}

# Get rawSql for a ClickHouse panel by panel id and refId (default "A").
# Searches all 3 dashboard files (panel id is unique across the set).
get_ch_sql() {
    local pid="$1"; local ref="${2:-A}"
    local df; df=$(find_panel_file "$pid")
    [ -z "$df" ] && { echo "[ERROR] panel $pid not found in any dashboard" >&2; return 1; }
    jq -r --arg pid "$pid" --arg ref "$ref" \
        '.panels[] | select(.id == ($pid | tonumber)) | .targets[] | select(.refId == $ref) | .rawSql' \
        "$df"
}

# Get expr for a Prometheus panel by panel id and refId (default "A").
# All Prometheus panels live in ops-health, but search all files for safety.
get_prom_expr() {
    local pid="$1"; local ref="${2:-A}"
    local df; df=$(find_panel_file "$pid")
    [ -z "$df" ] && { echo "[ERROR] panel $pid not found in any dashboard" >&2; return 1; }
    jq -r --arg pid "$pid" --arg ref "$ref" \
        '.panels[] | select(.id == ($pid | tonumber)) | .targets[] | select(.refId == $ref) | .expr' \
        "$df"
}

# ── Macro substitution ─────────────────────────────────────────────────
# Replaces $__timeFilter, ${api_key:singlequote}, ${model:singlequote}
# Uses sentinel tokens to avoid sed single-quote escaping hell.
sub_ch() {
    local sql="$1"
    local keys="${2:-$CH_KEY_LIST}"
    local models="${3:-$CH_MODEL_LIST}"
    # Step 1: $__timeFilter -- handle both timestamp and r.timestamp
    sql=$(printf '%s' "$sql" | sed \
        -e "s|\$__timeFilter(r\.timestamp)|r.timestamp >= toDateTime('$FROM_TS') AND r.timestamp <= toDateTime('$TO_TS')|g" \
        -e "s|\$__timeFilter(timestamp)|timestamp >= toDateTime('$FROM_TS') AND timestamp <= toDateTime('$TO_TS')|g")
    # Step 2: sentinel tokens for Grafana variables
    sql=$(printf '%s' "$sql" | sed \
        -e 's|\${api_key:singlequote}|APIKEYPLACEHOLDER|g' \
        -e 's|\${model:singlequote}|MODELPLACEHOLDER|g')
    # Step 3: bash string expansion (handles quotes in values)
    sql="${sql//APIKEYPLACEHOLDER/$keys}"
    sql="${sql//MODELPLACEHOLDER/$models}"
    printf '%s' "$sql"
}

# Substitute Prometheus $api_key variable with key regex (bash expansion, no sed delimiter issues)
sub_prom() {
    local expr="$1"
    local regex="${2:-$PROM_KEY_REGEX}"
    printf '%s' "${expr//\$api_key/$regex}"
}

# ── Execution helpers ──────────────────────────────────────────────────
exec_ch() {
    local sql; sql=$(sub_ch "$(get_ch_sql "$1" "$2")")
    curl -sf --max-time 30 -X POST "$CH_URL/" --data-binary "$sql" || echo ""
}

exec_ch_raw() {
    # $1 = already-substituted SQL
    curl -sf --max-time 30 -X POST "$CH_URL/" --data-binary "$1" || echo ""
}

exec_prom() {
    local expr; expr=$(sub_prom "$(get_prom_expr "$1" "$2")")
    local encoded; encoded=$(printf '%s' "$expr" | jq -sRr @uri)
    curl -sf --max-time 15 "$PROM_URL/api/v1/query?query=$encoded" || echo ""
}

prom_val() { echo "$1" | jq -r '.data.result[0].value[1] // empty' 2>/dev/null; }
prom_cnt() { echo "$1" | jq -r '.data.result | length' 2>/dev/null; }
prom_st()  { echo "$1" | jq -r '.status // "unknown"' 2>/dev/null; }
in_range() { awk "BEGIN{exit !($1 >= $2 && $1 <= $3)}" 2>/dev/null; }

# =====================================================================
# Q1: All ClickHouse panel queries return HTTP 200
# =====================================================================
echo "--- Q1: ClickHouse Query Execution (all panels, all targets) ---"
# Iterate over every ClickHouse panel + target across all 3 dashboards
while IFS=$'\t' read -r pid ref; do
    sql=$(sub_ch "$(get_ch_sql "$pid" "$ref")")
    hc=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 -X POST "$CH_URL/" --data-binary "$sql" || echo "000")
    [ "$hc" = "200" ] && rp "Q1: p${pid}-${ref} HTTP 200" || rf "Q1: p${pid}-${ref} HTTP $hc"
done < <(for df in "${ALL_DASHBOARDS[@]}"; do
    jq -r '.panels[] | select(.datasource.uid == "clickhouse") | .id as $pid | .targets[] | [$pid, .refId] | @tsv' "$df"
done)
echo ""

# =====================================================================
# Q2: p3 token consistency: total = input + cached + output + reasoning
# =====================================================================
echo "--- Q2: p3 Token Consistency ---"
# Extract the WITH totals CTE from p3 refId=A and select raw token columns
P3_CTE=$(get_ch_sql 3 A | sed -n '/^WITH totals AS/,/^)/p')
P3_RAW_SQL="${P3_CTE}
SELECT total_tok, input_tok, cached_tok, output_tok, reasoning_tok FROM totals FORMAT TabSeparated"
P3R=$(exec_ch_raw "$(sub_ch "$P3_RAW_SQL")")
PT=$(echo "$P3R" | cut -f1); PI=$(echo "$P3R" | cut -f2); PC=$(echo "$P3R" | cut -f3); PO=$(echo "$P3R" | cut -f4); PR=$(echo "$P3R" | cut -f5)
PT=${PT:-0}; PI=${PI:-0}; PC=${PC:-0}; PO=${PO:-0}; PR=${PR:-0}
PS=$((PI + PC + PO + PR))
[ "$PT" -eq "$PS" ] && rp "Q2: total($PT)=in($PI)+ca($PC)+out($PO)+re($PR)=$PS" || rf "Q2: total($PT)!=sum($PS)"
echo ""

# =====================================================================
# Q3: p3 all token counts >= 0, cost >= 0
# =====================================================================
echo "--- Q3: p3 Value Ranges (>= 0) ---"
for pair in "PT:total" "PI:input" "PC:cached" "PO:output" "PR:reasoning"; do
    var="${pair%%:*}"; name="${pair##*:}"; val="${!var}"
    [ "$val" -ge 0 ] 2>/dev/null && rp "Q3: $name=$val (>=0)" || rf "Q3: $name=$val (negative)"
done
# Total cost from p15 refId=A (Cost Over Time -- sum all rows)
TC=$(exec_ch 15 A | grep '.' | awk -F'\t' '{s+=$3} END{print s+0}'); TC=${TC:-0}
awk "BEGIN{exit !($TC >= 0)}" 2>/dev/null && rp "Q3: cost=$TC (>=0)" || rf "Q3: cost=$TC (negative)"
echo ""

# =====================================================================
# Q4: p3 format: "NN Mil ($X.XX)" or "NN K ($X.XX)" or "NN ($X.XX)"
# =====================================================================
echo "--- Q4: p3 Output Format ---"
P3_FMT_ROW=$(exec_ch 3 A | head -1)
P3_LABELS=(Total Input Cached Output Reasoning)
P3_IDX=0
IFS=$'\t' read -r -a P3_COLS <<< "$P3_FMT_ROW"
for val in "${P3_COLS[@]}"; do
    label="${P3_LABELS[$P3_IDX]}"
    if echo "$val" | grep -qE '^[0-9]+ (Mil|K) \(\$[0-9]+\.[0-9]+\)$' \
        || echo "$val" | grep -qE '^[0-9]+ \(\$[0-9]+(\.[0-9]+)?\)$'; then
        rp "Q4: p3-${label} format valid"
    else
        rf "Q4: p3-${label} format invalid: $val"
    fi
    P3_IDX=$((P3_IDX + 1))
done
[ "${#P3_COLS[@]}" -eq 5 ] && rp "Q4: p3 returns 5 formatted columns" || rf "Q4: p3 returns ${#P3_COLS[@]} columns (expected 5)"
echo ""

# =====================================================================
# Q5: p13 abort rates in [0, 100]
# =====================================================================
echo "--- Q5: p13 Abort Rate Range [0,100] ---"
for ref in A B; do
    exec_ch 13 "$ref" | grep '.' | while IFS=$'\t' read -r t l v; do
        in_range "$v" 0 100 && rp "Q5: p13-${ref} $t rate=$v" || rf "Q5: p13-${ref} $t rate=$v out of range"
    done
done
echo ""

# =====================================================================
# Q6: p14 partition: completed + client_ab + provider_ab ≈ total streams
# (ASOF JOIN may miss a few rows; allow <=2% tolerance)
# =====================================================================
echo "--- Q6: p14 Stream Partition Consistency ---"
P14C=$(exec_ch 14 A | grep '.' | awk -F'\t' '{s+=$3} END{print s+0}')
P14CA=$(exec_ch 14 B | grep '.' | awk -F'\t' '{s+=$3} END{print s+0}')
P14PA=$(exec_ch 14 C | grep '.' | awk -F'\t' '{s+=$3} END{print s+0}')
# Total streams = count of all stream rows in usage_log
P14T_SQL=$(sub_ch "SELECT count() FROM llm_gateway.usage_log WHERE \$__timeFilter(timestamp) AND coalesce(nullIf(key_id,''), nullIf(api_key_id,''), 'unknown') IN (\${api_key:singlequote}) AND is_stream = 1")
P14T=$(exec_ch_raw "$P14T_SQL" | head -1); P14T=${P14T:-0}
P14S=$((P14C + P14CA + P14PA))
P14DIFF=$((P14T - P14S))
if [ "$P14DIFF" -lt 0 ]; then P14DIFF=$((-P14DIFF)); fi
P14PCT=$(awk "BEGIN{if($P14T > 0) printf \"%.2f\", ($P14DIFF * 100.0 / $P14T); else print 0}" 2>/dev/null)
P14OK=$(awk "BEGIN{print ($P14PCT <= 2.0) ? 1 : 0}" 2>/dev/null)
[ "$P14OK" = "1" ] && rp "Q6: comp($P14C)+cli($P14CA)+prov($P14PA)=$P14S≈total($P14T) diff=${P14DIFF} (${P14PCT}%)" \
    || rf "Q6: sum($P14S)!=total($P14T) diff=${P14DIFF} (${P14PCT}%)"
echo ""

# =====================================================================
# Q7: p15 cost sum = total cost (cross-query consistency)
# =====================================================================
echo "--- Q7: p15 Cost Sum = Total Cost ---"
P15S=$(exec_ch 15 A | grep '.' | awk -F'\t' '{s+=$3} END{print s+0}')
# Total cost = sum(cost) from usage_log with same filters
P15T_SQL=$(sub_ch "SELECT round(sum(cost), 6) FROM llm_gateway.usage_log WHERE \$__timeFilter(timestamp) AND coalesce(nullIf(key_id,''), nullIf(api_key_id,''), 'unknown') IN (\${api_key:singlequote}) AND model IN (\${model:singlequote})")
P15T=$(exec_ch_raw "$P15T_SQL" | head -1); P15T=${P15T:-0}
P7DIFF=$(awk "BEGIN{d=$P15S-$P15T; if(d<0)d=-d; print d}" 2>/dev/null)
awk "BEGIN{exit !($P7DIFF < 0.01)}" 2>/dev/null && rp "Q7: cost_sum($P15S)~=total($P15T) diff=$P7DIFF" || rf "Q7: cost_sum($P15S)!=total($P15T) diff=$P7DIFF"
echo ""

# =====================================================================
# Q8: p8 model dist sum ≈ total requests (ASOF JOIN may miss rows; <=2% tolerance)
# p8 (Model Distribution) is in cost-usage; p1 (Total Requests) is in ops-health.
# Both are ClickHouse; get_ch_sql auto-detects the correct file per panel id.
# =====================================================================
echo "--- Q8: p8 Model Distribution Consistency ---"
P8D=$(exec_ch 8 A)
P8S=$(echo "$P8D" | grep '.' | awk -F'\t' '{s+=$2} END{print s+0}')
# Compare against usage_log row count (p8 counts usage_log rows per model)
P8T_SQL="SELECT count() FROM llm_gateway.usage_log WHERE timestamp >= toDateTime('$FROM_TS') AND timestamp <= toDateTime('$TO_TS') AND model != '' AND coalesce(nullIf(key_id,''), nullIf(api_key_id,''), 'unknown') IN ($CH_KEY_LIST) AND model IN ($CH_MODEL_LIST) FORMAT TabSeparated"
P8T=$(exec_ch_raw "$P8T_SQL" | head -1); P8T=${P8T:-0}
P8DIFF=$((P8T - P8S))
if [ "$P8DIFF" -lt 0 ]; then P8DIFF=$((-P8DIFF)); fi
P8PCT=$(awk "BEGIN{if($P8T > 0) printf \"%.2f\", ($P8DIFF * 100.0 / $P8T); else print 0}" 2>/dev/null)
P8OK=$(awk "BEGIN{print ($P8PCT <= 2.0) ? 1 : 0}" 2>/dev/null)
[ "$P8OK" = "1" ] && rp "Q8: dist_sum($P8S)≈total($P8T) diff=${P8DIFF} (${P8PCT}%)" \
    || rf "Q8: dist_sum($P8S)!=total($P8T) diff=${P8DIFF} (${P8PCT}%)"
echo "$P8D" | grep '.' | while IFS=$'\t' read -r m c; do
    [ "$c" -gt 0 ] 2>/dev/null && rp "Q8: '$m' count=$c (>0)" || rf "Q8: '$m' count=$c (<=0)"
done
echo ""

# =====================================================================
# Q9: p10 avg latency in (0, 300); model names non-empty
# =====================================================================
echo "--- Q9: p10 Avg Response Time Range (0, 300) ---"
P10R=$(exec_ch 10 A)
if [ -z "$P10R" ]; then
    rs "Q9: p10 no latency data"
else
    echo "$P10R" | grep '.' | while IFS=$'\t' read -r m lat; do
        [ -z "$m" ] && { rf "Q9: empty model name lat=$lat"; return; }
        in_range "$lat" 0.001 300 && rp "Q9: '$m' lat=${lat}s in (0,300)" || rf "Q9: '$m' lat=${lat}s out of range"
    done
fi
echo ""

# =====================================================================
# Q10: All Prometheus queries return status=success with >=1 result
# (status=success with 0 results = query valid but no data = broken pipeline)
# =====================================================================
echo "--- Q10: Prometheus Query Execution (all panels, all targets) ---"
while IFS=$'\t' read -r pid ref; do
    resp=$(exec_prom "$pid" "$ref")
    st=$(prom_st "$resp"); cnt=$(prom_cnt "$resp")
    if [ "$st" != "success" ]; then
        rf "Q10: p${pid}-${ref}: status=$st"
    elif [ "$cnt" -lt 1 ] 2>/dev/null; then
        rf "Q10: p${pid}-${ref}: success but 0 results (APISIX scraping broken?)"
    else
        rp "Q10: p${pid}-${ref}: success ($cnt results)"
    fi
done < <(for df in "${ALL_DASHBOARDS[@]}"; do
    jq -r '.panels[] | select(.datasource.uid == "prometheus") | .id as $pid | .targets[] | [$pid, .refId] | @tsv' "$df"
done)
echo ""

# =====================================================================
# Q11: p4 Error Rate from ClickHouse in [0, 100], and > 0 if 4xx+5xx exist
# =====================================================================
echo "--- Q11: p4 Error Rate (ClickHouse, status >= 400) ---"
P4V=$(exec_ch 4 A | head -1); P4V=${P4V:-0}
in_range "$P4V" 0 100 && rp "Q11: error_rate=$P4V in [0,100]" || rf "Q11: error_rate=$P4V out of range"
# Cross-check: count 4xx+5xx errors directly
P4ERR_SQL=$(sub_ch "SELECT countIf(status >= 400) FROM llm_gateway.request_log WHERE \$__timeFilter(timestamp) AND coalesce(nullIf(key_id,''), nullIf(api_key_id,''), 'unknown') IN (\${api_key:singlequote})")
P4ERR=$(exec_ch_raw "$P4ERR_SQL" | head -1); P4ERR=${P4ERR:-0}
if [ "$P4ERR" -gt 0 ] 2>/dev/null; then
    awk "BEGIN{exit !($P4V > 0)}" 2>/dev/null && rp "Q11: 4xx+5xx errors=$P4ERR, error_rate=$P4V (>0)" \
        || rf "Q11: 4xx+5xx errors=$P4ERR but error_rate=$P4V (should be >0)"
else
    rp "Q11: no 4xx+5xx errors in range, error_rate=$P4V (0 is correct)"
fi
echo ""

# =====================================================================
# Q12: p9 latency ordering: p50 <= p95 <= p99
# (Stack is running and APISIX is scraping -- no data = broken pipeline = FAIL)
# =====================================================================
echo "--- Q12: p9 Latency Percentile Ordering ---"
P50=$(prom_val "$(exec_prom 9 A)")
P95=$(prom_val "$(exec_prom 9 B)")
P99=$(prom_val "$(exec_prom 9 C)")
if [ -z "$P50" ] || [ -z "$P95" ] || [ -z "$P99" ]; then
    rf "Q12: missing latency data (p50=$P50 p95=$P95 p99=$P99) -- APISIX histogram scraping broken"
else
    awk "BEGIN{exit !($P50 <= $P95 && $P95 <= $P99)}" 2>/dev/null && rp "Q12: p50($P50)<=p95($P95)<=p99($P99)" || rf "Q12: ordering broken (p50=$P50 p95=$P95 p99=$P99)"
fi
echo ""

# =====================================================================
# Q13: p12 shared dict usage in [0, 100]
# (Stack is running -- no data = broken scraping = FAIL)
# =====================================================================
echo "--- Q13: p12 Shared Dict Usage Range [0,100] ---"
P12K=$(prom_val "$(exec_prom 12 A)")
P12R=$(prom_val "$(exec_prom 12 B)")
for pair in "P12K:key_cache" "P12R:redact_state"; do
    var="${pair%%:*}"; name="${pair##*:}"; val="${!var}"
    if [ -z "$val" ]; then
        rf "Q13: $name no data -- APISIX shared_dict scraping broken"
    else
        in_range "$val" 0 100 && rp "Q13: $name=$val in [0,100]" || rf "Q13: $name=$val out of range"
    fi
done
echo ""

# =====================================================================
# Q14: Single key filter: filtered < all keys (ClickHouse, multiple panels)
# Tests that the ${api_key:singlequote} filter actually narrows results.
# Uses p1 (Total Requests) and p3 (Token Usage) -- both ClickHouse, both
# use the api_key variable. No Prometheus (p1 is ClickHouse now).
# =====================================================================
echo "--- Q14: Single Key Filter (filtered < all, ClickHouse) ---"
SK=$(echo "$ALL_KEYS" | head -1)
if [ -z "$SK" ] || [ "$SK" = "unknown" ]; then
    rf "Q14: no keys available (cannot test filter)"
else
    SKL="'$SK'"
    # p1 Total Requests: single key vs all keys
    P1_SINGLE=$(exec_ch_raw "$(sub_ch "$(get_ch_sql 1 A)" "$SKL")")
    P1_SINGLE=${P1_SINGLE:-0}
    P1_ALL=$(exec_ch 1 A | head -1); P1_ALL=${P1_ALL:-0}
    [ "$P1_SINGLE" -lt "$P1_ALL" ] 2>/dev/null \
        && rp "Q14: p1 single_key($P1_SINGLE) < all_keys($P1_ALL)" \
        || rf "Q14: p1 single($P1_SINGLE) >= all($P1_ALL) -- filter not narrowing"

    # p3 Token Usage: single key total tokens < all keys total tokens
    P3_CTE=$(get_ch_sql 3 A | sed -n '/^WITH totals AS/,/^)/p')
    P3_RAW_SQL="${P3_CTE}
SELECT total_tok FROM totals FORMAT TabSeparated"
    P3_SINGLE=$(exec_ch_raw "$(sub_ch "$P3_RAW_SQL" "$SKL" "$CH_MODEL_LIST")" | cut -f1)
    P3_SINGLE=${P3_SINGLE:-0}
    [ "$P3_SINGLE" -lt "$PT" ] 2>/dev/null \
        && rp "Q14: p3 single_key_tokens($P3_SINGLE) < all_tokens($PT)" \
        || rf "Q14: p3 single($P3_SINGLE) >= all($PT) -- filter not narrowing"

    # p4 Error Rate: single key query returns HTTP 200 (filter doesn't break SQL)
    P4_SQL=$(sub_ch "$(get_ch_sql 4 A)" "$SKL")
    P4_HC=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 -X POST "$CH_URL/" --data-binary "$P4_SQL" || echo "000")
    [ "$P4_HC" = "200" ] && rp "Q14: p4 single_key HTTP 200" || rf "Q14: p4 single_key HTTP $P4_HC"
fi
echo ""

# =====================================================================
# Q15: Single model filter: no SQL error (HTTP 200)
# =====================================================================
echo "--- Q15: Single Model Filter (HTTP 200) ---"
SM=$(echo "$ALL_MODELS" | head -1)
if [ -n "$SM" ] && [ "$SM" != "unknown" ]; then
    SML="'$SM'"
    for pid_ref in "3:A" "8:A" "15:A"; do
        pid="${pid_ref%%:*}"; ref="${pid_ref##*:}"
        sql=$(sub_ch "$(get_ch_sql "$pid" "$ref")" "$CH_KEY_LIST" "$SML")
        hc=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 -X POST "$CH_URL/" --data-binary "$sql" || echo "000")
        [ "$hc" = "200" ] && rp "Q15: p${pid}-${ref} single model HTTP 200" || rf "Q15: p${pid}-${ref} single model HTTP $hc"
    done
else
    rs "Q15: no models available"
fi
echo ""

# =====================================================================
# Q16: Dashboard macro verification (no $__conditionalAll, no allValue, UNION)
# Checks all 3 dashboards; templating is identical so api_key/model checks
# only need one file (use cost-usage as canonical).
# =====================================================================
echo "--- Q16: Dashboard Macro Verification ---"
CA=0
for df in "${ALL_DASHBOARDS[@]}"; do
    c=$(jq '[.panels[].targets[]|(.rawSql//.expr//"")|select(.!=null)|select(test("\\$\\$__conditionalAll"))]|length' "$df" 2>/dev/null || echo 0)
    CA=$((CA + c))
done
[ "$CA" = "0" ] && rp "Q16: no \$__conditionalAll (all 3 dashboards)" || rf "Q16: $CA conditionalAll macros found"
AK=$(jq -r '[.templating.list[]|select(.name=="api_key")]|if length==0 then "error" else (.[0].allValue|if .==null or .=="" then "None" else . end) end' "$COST_USAGE_FILE" 2>/dev/null || echo "error")
[ "$AK" = "None" ] && rp "Q16: api_key no allValue" || rf "Q16: api_key allValue=$AK"
MQ=$(jq -r '[.templating.list[]|select(.name=="model")]|if length==0 then "error" else (.[0].query|ascii_upcase|if test("UNION") then "union" else "single" end) end' "$COST_USAGE_FILE" 2>/dev/null || echo "error")
[ "$MQ" = "union" ] && rp "Q16: model variable UNIONs both tables" || rf "Q16: model variable no UNION"
echo ""

# =====================================================================
# Summary
# =====================================================================
echo ""
echo "Dashboard query tests: $pass passed, $fail failed, $skip skipped"
[ "$fail" -gt 0 ] && exit 1 || exit 0
