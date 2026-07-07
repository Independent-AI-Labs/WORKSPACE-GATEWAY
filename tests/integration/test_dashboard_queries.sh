#!/bin/bash
set -euo pipefail

# Dashboard Query Integration Tests (Q1-Q16)
# SQL: tests/integration/queries/*.sql | YAML: tests/integration/queries/prometheus.yaml
# Placeholders: __FROM__, __TO__, __API_KEYS__, __MODELS__, __API_KEY_REGEX__

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
QUERIES_DIR="$SCRIPT_DIR/queries"
DASHBOARD_FILE="$REPO_ROOT/conf/grafana/dashboards/gateway-overview.json"

CH_URL="http://localhost:8123"
PROM_URL="http://localhost:9092"
GATEWAY_URL="http://localhost:9080"

pass=0; fail=0; skip=0
rp() { echo "[PASS] $1"; pass=$((pass+1)); }
rf() { echo "[FAIL] $1"; fail=$((fail+1)); }
rs() { echo "[SKIP] $1"; skip=$((skip+1)); }

# Skip if stack not running
curl_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$GATEWAY_URL/" 2>/dev/null || echo "000")
[ "$curl_code" = "000" ] && { echo "[SKIP] APISIX not reachable"; exit 0; }
ch_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$CH_URL/?query=SELECT%201" 2>/dev/null || echo "000")
[ "$ch_code" != "200" ] && { echo "[SKIP] ClickHouse not reachable"; exit 0; }
prom_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$PROM_URL/-/healthy" 2>/dev/null || echo "000")
[ "$prom_code" != "200" ] && { echo "[SKIP] Prometheus not reachable"; exit 0; }

echo "=== Dashboard Query Integration Tests ==="
echo ""

# Time range (last 24h)
FROM_TS=$(date -d '24 hours ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || \
    date -u -d "@$(($(date +%s)-86400))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || \
    date -u -r "$(( $(date +%s) - 86400 ))" '+%Y-%m-%d %H:%M:%S')
TO_TS=$(date '+%Y-%m-%d %H:%M:%S')
echo "[INFO] Time range: $FROM_TS to $TO_TS"

# Fetch all key hashes
ALL_KEYS=$(curl -sf "$CH_URL/" --data-binary \
    "SELECT DISTINCT coalesce(nullIf(key_id,''), nullIf(api_key_id,''), 'unknown') AS k FROM llm_gateway.usage_log ORDER BY k FORMAT TabSeparated" \
    2>/dev/null || echo "")
[ -z "$ALL_KEYS" ] && ALL_KEYS=$(curl -sf "$CH_URL/" --data-binary \
    "SELECT DISTINCT coalesce(nullIf(key_id,''), nullIf(api_key_id,''), 'unknown') AS k FROM llm_gateway.request_log ORDER BY k FORMAT TabSeparated" \
    2>/dev/null || echo "")
[ -z "$ALL_KEYS" ] && ALL_KEYS="unknown"
CH_KEY_LIST=$(echo "$ALL_KEYS" | grep '.' | sed "s/^/'/; s/$/'/" | paste -sd, -)
[ -z "$CH_KEY_LIST" ] && CH_KEY_LIST="'unknown'"
PROM_KEY_REGEX=$(echo "$ALL_KEYS" | grep '.' | paste -sd '|' -)
[ -z "$PROM_KEY_REGEX" ] && PROM_KEY_REGEX=".*"
echo "[INFO] Keys: $(echo "$ALL_KEYS" | grep -c '.' || true)"

# Fetch all models (UNION of both tables)
ALL_MODELS=$(curl -sf "$CH_URL/" --data-binary \
    "SELECT DISTINCT model FROM (SELECT model FROM llm_gateway.request_log WHERE model != '' UNION ALL SELECT model FROM llm_gateway.usage_log WHERE model != '') ORDER BY model FORMAT TabSeparated" \
    2>/dev/null || echo "")
[ -z "$ALL_MODELS" ] && ALL_MODELS="unknown"
CH_MODEL_LIST=$(echo "$ALL_MODELS" | grep '.' | sed "s/^/'/; s/$/'/" | paste -sd, -)
[ -z "$CH_MODEL_LIST" ] && CH_MODEL_LIST="'unknown'"
echo "[INFO] Models: $(echo "$ALL_MODELS" | grep -c '.' || true)"
echo ""

# Helpers
sub_sql() { sed -e "s|__FROM__|'$1'|g" -e "s|__TO__|'$2'|g" -e "s|__API_KEYS__|$3|g" -e "s|__MODELS__|$4|g" "$5"; }
url_enc() { printf '%s' "$1" | jq -sRr @uri; }
exec_ch() { local sql; sql=$(sub_sql "$FROM_TS" "$TO_TS" "$CH_KEY_LIST" "$CH_MODEL_LIST" "$QUERIES_DIR/$1"); curl -sf --max-time 30 -X POST "$CH_URL/" --data-binary "$sql" 2>/dev/null || echo ""; }
exec_prom() { curl -sf --max-time 15 "$PROM_URL/api/v1/query?query=$(url_enc "$1")" 2>/dev/null || echo ""; }
prom_val() { echo "$1" | jq -r '.data.result[0].value[1] // empty' 2>/dev/null; }
prom_cnt() { echo "$1" | jq -r '.data.result | length' 2>/dev/null; }
prom_st() { echo "$1" | jq -r '.status // "unknown"' 2>/dev/null; }
in_range() { awk "BEGIN{exit !($1 >= $2 && $1 <= $3)}" 2>/dev/null; }

# Q1: All ClickHouse panel queries return HTTP 200
echo "--- Q1: ClickHouse Query Execution ---"
for sf in p3_total.sql p3_input.sql p3_cached.sql p3_output.sql p3_reasoning.sql p3_raw_tokens.sql \
    p8_model_dist.sql p8_total_requests.sql p10_avg_latency.sql \
    p13_abort_client.sql p13_abort_provider.sql \
    p14_completed.sql p14_client_aborted.sql p14_provider_aborted.sql p14_total_streams.sql \
    p15_cost_over_time.sql p15_total_cost.sql; do
    sql=$(sub_sql "$FROM_TS" "$TO_TS" "$CH_KEY_LIST" "$CH_MODEL_LIST" "$QUERIES_DIR/$sf")
    hc=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 -X POST "$CH_URL/" --data-binary "$sql" 2>/dev/null || echo "000")
    [ "$hc" = "200" ] && rp "Q1: $sf HTTP 200" || rf "Q1: $sf HTTP $hc"
done
echo ""

# Q2: p3 token consistency: total = input + cached + output + reasoning
echo "--- Q2: p3 Token Consistency ---"
P3R=$(exec_ch "p3_raw_tokens.sql")
PT=$(echo "$P3R" | cut -f1); PI=$(echo "$P3R" | cut -f2); PC=$(echo "$P3R" | cut -f3); PO=$(echo "$P3R" | cut -f4); PR=$(echo "$P3R" | cut -f5)
PT=${PT:-0}; PI=${PI:-0}; PC=${PC:-0}; PO=${PO:-0}; PR=${PR:-0}
PS=$((PI + PC + PO + PR))
[ "$PT" -eq "$PS" ] && rp "Q2: total($PT)=in($PI)+ca($PC)+out($PO)+re($PR)=$PS" || rf "Q2: total($PT)!=sum($PS)"
echo ""

# Q3: p3 all token counts >= 0, cost >= 0
echo "--- Q3: p3 Value Ranges (>= 0) ---"
for pair in "PT:total" "PI:input" "PC:cached" "PO:output" "PR:reasoning"; do
    var="${pair%%:*}"; name="${pair##*:}"; val="${!var}"
    [ "$val" -ge 0 ] 2>/dev/null && rp "Q3: $name=$val (>=0)" || rf "Q3: $name=$val (negative)"
done
TC=$(exec_ch "p15_total_cost.sql" | head -1); TC=${TC:-0}
awk "BEGIN{exit !($TC >= 0)}" 2>/dev/null && rp "Q3: cost=$TC (>=0)" || rf "Q3: cost=$TC (negative)"
echo ""

# Q4: p3 format: "NN Mil ($X.XX)" or "NN K ($X.XX)" or "NN ($X.XX)"
echo "--- Q4: p3 Output Format ---"
for sf in p3_total.sql p3_input.sql p3_cached.sql p3_output.sql p3_reasoning.sql; do
    r=$(exec_ch "$sf")
    if echo "$r" | grep -qP '^\d+ (Mil|K) \(\$\d+\.\d+\)$' || echo "$r" | grep -qP '^\d+ \(\$\d+(\.\d+)?\)$'; then
        rp "Q4: $sf format valid"
    else
        rf "Q4: $sf format invalid: $(echo "$r" | head -1)"
    fi
done
echo ""

# Q5: p13 abort rates in [0, 100]
echo "--- Q5: p13 Abort Rate Range [0,100] ---"
for sf in p13_abort_client.sql p13_abort_provider.sql; do
    exec_ch "$sf" | grep '.' | while IFS=$'\t' read -r t l v; do
        in_range "$v" 0 100 && rp "Q5: $sf $t rate=$v" || rf "Q5: $sf $t rate=$v out of range"
    done
done
echo ""

# Q6: p14 partition: completed + client_ab + provider_ab = total streams
echo "--- Q6: p14 Stream Partition Consistency ---"
P14C=$(exec_ch "p14_completed.sql" | grep '.' | awk -F'\t' '{s+=$3} END{print s+0}')
P14CA=$(exec_ch "p14_client_aborted.sql" | grep '.' | awk -F'\t' '{s+=$3} END{print s+0}')
P14PA=$(exec_ch "p14_provider_aborted.sql" | grep '.' | awk -F'\t' '{s+=$3} END{print s+0}')
P14T=$(exec_ch "p14_total_streams.sql" | head -1); P14T=${P14T:-0}
P14S=$((P14C + P14CA + P14PA))
[ "$P14S" -eq "$P14T" ] && rp "Q6: comp($P14C)+cli($P14CA)+prov($P14PA)=$P14S=total($P14T)" || rf "Q6: sum($P14S)!=total($P14T)"
echo ""

# Q7: p15 cost sum = p15 total cost (cross-query consistency)
echo "--- Q7: p15 Cost Sum = Total Cost ---"
P15S=$(exec_ch "p15_cost_over_time.sql" | grep '.' | awk -F'\t' '{s+=$3} END{print s+0}')
P15T=$(exec_ch "p15_total_cost.sql" | head -1); P15T=${P15T:-0}
P7DIFF=$(awk "BEGIN{d=$P15S-$P15T; if(d<0)d=-d; print d}" 2>/dev/null)
awk "BEGIN{exit !($P7DIFF < 0.01)}" 2>/dev/null && rp "Q7: cost_sum($P15S)~=total($P15T) diff=$P7DIFF" || rf "Q7: cost_sum($P15S)!=total($P15T) diff=$P7DIFF"
echo ""

# Q8: p8 model dist sum = total requests; each count > 0
echo "--- Q8: p8 Model Distribution Consistency ---"
P8D=$(exec_ch "p8_model_dist.sql")
P8S=$(echo "$P8D" | grep '.' | awk -F'\t' '{s+=$2} END{print s+0}')
P8T=$(exec_ch "p8_total_requests.sql" | head -1); P8T=${P8T:-0}
[ "$P8S" -eq "$P8T" ] && rp "Q8: dist_sum($P8S)=total($P8T)" || rf "Q8: dist_sum($P8S)!=total($P8T)"
echo "$P8D" | grep '.' | while IFS=$'\t' read -r m c; do
    [ "$c" -gt 0 ] 2>/dev/null && rp "Q8: '$m' count=$c (>0)" || rf "Q8: '$m' count=$c (<=0)"
done
echo ""

# Q9: p10 avg latency in (0, 300); model names non-empty
echo "--- Q9: p10 Avg Latency Range (0, 300) ---"
P10R=$(exec_ch "p10_avg_latency.sql")
if [ -z "$P10R" ]; then
    rs "Q9: p10 no latency data"
else
    echo "$P10R" | grep '.' | while IFS=$'\t' read -r m lat; do
        [ -z "$m" ] && { rf "Q9: empty model name lat=$lat"; return; }
        in_range "$lat" 0.001 300 && rp "Q9: '$m' lat=${lat}s in (0,300)" || rf "Q9: '$m' lat=${lat}s out of range"
    done
fi
echo ""

# Q10: All Prometheus queries return status=success with >=1 result
echo "--- Q10: Prometheus Query Execution ---"
source "$REPO_ROOT/tests/config/yaml_helpers.sh"
PJ=$(yaml_to_json "$QUERIES_DIR/prometheus.yaml")
if [ -z "$PJ" ]; then
    rf "Q10: Failed to parse prometheus.yaml"
else
    echo "$PJ" | jq -r --arg rx "$PROM_KEY_REGEX" \
        '.[] | [.panel, .refId, .title, (.expr | gsub("__API_KEY_REGEX__"; $rx))] | @tsv' \
    | while IFS=$'\t' read -r p ref title expr; do
        resp=$(exec_prom "$expr")
        st=$(prom_st "$resp"); cnt=$(prom_cnt "$resp")
        [ "$st" = "success" ] && rp "Q10: p${p}-${ref} ${title}: success ($cnt)" || rf "Q10: p${p}-${ref}: status=$st"
    done
fi
echo ""

# Q11: p4 error rate in [0, 100]
echo "--- Q11: p4 Error Rate Range [0,100] ---"
P4V=$(prom_val "$(exec_prom "(sum(rate(apisix_http_status{key_hash=~\"$PROM_KEY_REGEX\",code=~\"5..\"}[5m])) or vector(0)) / sum(rate(apisix_http_status{key_hash=~\"$PROM_KEY_REGEX\"}[5m])) * 100")")
[ -z "$P4V" ] && rs "Q11: no data" || { in_range "$P4V" 0 100 && rp "Q11: error_rate=$P4V in [0,100]" || rf "Q11: error_rate=$P4V out of range"; }
echo ""

# Q12: p9 latency ordering: p50 <= p95 <= p99
echo "--- Q12: p9 Latency Percentile Ordering ---"
P50=$(prom_val "$(exec_prom "histogram_quantile(0.50, sum by (le) (rate(apisix_http_latency_bucket{key_hash=~\"$PROM_KEY_REGEX\",type=\"apisix\"}[5m]))) * 1000")")
P95=$(prom_val "$(exec_prom "histogram_quantile(0.95, sum by (le) (rate(apisix_http_latency_bucket{key_hash=~\"$PROM_KEY_REGEX\",type=\"apisix\"}[5m]))) * 1000")")
P99=$(prom_val "$(exec_prom "histogram_quantile(0.99, sum by (le) (rate(apisix_http_latency_bucket{key_hash=~\"$PROM_KEY_REGEX\",type=\"apisix\"}[5m]))) * 1000")")
if [ -z "$P50" ] || [ -z "$P95" ] || [ -z "$P99" ]; then
    rs "Q12: incomplete (p50=$P50 p95=$P95 p99=$P99)"
else
    awk "BEGIN{exit !($P50 <= $P95 && $P95 <= $P99)}" 2>/dev/null && rp "Q12: p50($P50)<=p95($P95)<=p99($P99)" || rf "Q12: ordering broken"
fi
echo ""

# Q13: p12 shared dict usage in [0, 100]
echo "--- Q13: p12 Shared Dict Usage Range [0,100] ---"
P12K=$(prom_val "$(exec_prom "(1 - apisix_shared_dict_free_space_bytes{name=\"key_cache\"} / apisix_shared_dict_capacity_bytes{name=\"key_cache\"}) * 100")")
P12R=$(prom_val "$(exec_prom "(1 - apisix_shared_dict_free_space_bytes{name=\"redact_state\"} / apisix_shared_dict_capacity_bytes{name=\"redact_state\"}) * 100")")
for pair in "P12K:key_cache" "P12R:redact_state"; do
    var="${pair%%:*}"; name="${pair##*:}"; val="${!var}"
    [ -z "$val" ] && rs "Q13: $name no data" || { in_range "$val" 0 100 && rp "Q13: $name=$val in [0,100]" || rf "Q13: $name=$val out of range"; }
done
echo ""

# Q14: Single key filter: filtered <= unfiltered
echo "--- Q14: Single Key Filter (filtered <= unfiltered) ---"
SK=$(echo "$ALL_KEYS" | head -1)
if [ -n "$SK" ] && [ "$SK" != "unknown" ]; then
    SKL="'$SK'"
    ssql=$(sub_sql "$FROM_TS" "$TO_TS" "$SKL" "$CH_MODEL_LIST" "$QUERIES_DIR/p3_raw_tokens.sql")
    sraw=$(curl -sf --max-time 30 -X POST "$CH_URL/" --data-binary "$ssql" 2>/dev/null || echo "")
    stot=$(echo "$sraw" | cut -f1); stot=${stot:-0}
    [ "$stot" -le "$PT" ] 2>/dev/null && rp "Q14: single_key_total($stot)<=all($PT)" || rf "Q14: single($stot)>all($PT)"
    P1S=$(prom_val "$(exec_prom "sum(apisix_http_status{key_hash=~\"$SK\"})")")
    P1A=$(prom_val "$(exec_prom "sum(apisix_http_status{key_hash=~\"$PROM_KEY_REGEX\"})")")
    if [ -n "$P1S" ] && [ -n "$P1A" ]; then
        awk "BEGIN{exit !($P1S <= $P1A)}" 2>/dev/null && rp "Q14: p1 single($P1S)<=all($P1A)" || rf "Q14: p1 single($P1S)>all($P1A)"
    else
        rs "Q14: p1 prometheus no data"
    fi
else
    rs "Q14: no keys available"
fi
echo ""

# Q15: Single model filter: no SQL error (HTTP 200)
echo "--- Q15: Single Model Filter (HTTP 200) ---"
SM=$(echo "$ALL_MODELS" | head -1)
if [ -n "$SM" ] && [ "$SM" != "unknown" ]; then
    SML="'$SM'"
    for sf in p3_total.sql p8_model_dist.sql p15_cost_over_time.sql; do
        sql=$(sub_sql "$FROM_TS" "$TO_TS" "$CH_KEY_LIST" "$SML" "$QUERIES_DIR/$sf")
        hc=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 -X POST "$CH_URL/" --data-binary "$sql" 2>/dev/null || echo "000")
        [ "$hc" = "200" ] && rp "Q15: $sf single model HTTP 200" || rf "Q15: $sf single model HTTP $hc"
    done
else
    rs "Q15: no models available"
fi
echo ""

# Q16: Dashboard macro verification
echo "--- Q16: Dashboard Macro Verification ---"
CA=$(jq '[.panels[].targets[]|(.rawSql//.expr//"")|select(.!=null)|select(test("\\$\\$__conditionalAll"))]|length' "$DASHBOARD_FILE" 2>/dev/null || echo "error")
[ "$CA" = "0" ] && rp "Q16: no \$__conditionalAll" || rf "Q16: $CA conditionalAll macros found"
AK=$(jq -r '[.templating.list[]|select(.name=="api_key")]|if length==0 then "error" else (.[0].allValue|if .==null or .=="" then "None" else . end) end' "$DASHBOARD_FILE" 2>/dev/null || echo "error")
[ "$AK" = "None" ] && rp "Q16: api_key no allValue" || rf "Q16: api_key allValue=$AK"
MQ=$(jq -r '[.templating.list[]|select(.name=="model")]|if length==0 then "error" else (.[0].query|ascii_upcase|if test("UNION") then "union" else "single" end) end' "$DASHBOARD_FILE" 2>/dev/null || echo "error")
[ "$MQ" = "union" ] && rp "Q16: model variable UNIONs both tables" || rf "Q16: model variable no UNION"
echo ""

# Summary
echo ""
echo "Dashboard query tests: $pass passed, $fail failed, $skip skipped"
[ "$fail" -gt 0 ] && exit 1 || exit 0
