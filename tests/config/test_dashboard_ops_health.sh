#!/bin/bash
set -euo pipefail

# Structure tests for Dashboard 2: Gateway Operations & Health
# (conf/grafana/dashboards/gateway-ops-health.json)
# Panels: p1 Total Requests, p4 Error Rate, p2 Active Connections, p5 Request Rate,
#         p7 Status Code Breakdown, p13 Stream Abort Rate, p14 Stream Status,
#         p9 Latency p50/p95/p99, p10 Avg Response Time by Model, p11 Bandwidth, p12 Shared Dict

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/dashboard_assert.sh"

F="$OPS_HEALTH_FILE"
LABEL="ops-health"

echo "=== Dashboard Structure Tests: Gateway Operations & Health ==="
echo ""

[ -f "$F" ] || { echo "[FAIL] $LABEL missing: $F"; fail=$((fail+1)); summary "test_dashboard_ops_health.sh"; }

assert_json_valid "$LABEL: dashboard JSON is valid" "$F"

# Identity
assert_eq "$LABEL: title is Gateway Operations & Health" "Gateway Operations & Health" "$(jq -r '.title' "$F")"
assert_eq "$LABEL: uid is gateway-ops-health" "gateway-ops-health" "$(jq -r '.uid' "$F")"

# Panel count and datasource split (11 panels: 6 ClickHouse, 5 Prometheus)
assert_eq "$LABEL: panel count is 11" "11" "$(jq '.panels|length' "$F")"
assert_eq "$LABEL: ClickHouse panels" "6" "$(jq '[.panels[]|select(.datasource.uid=="clickhouse")]|length' "$F")"
assert_eq "$LABEL: Prometheus panels" "5" "$(jq '[.panels[]|select(.datasource.uid=="prometheus")]|length' "$F")"

# Generic structural checks
check_dashboard_basics "$F" "$LABEL"

# S3: Prometheus timeseries with fixed legend all aggregate to 1 series
PROM_NO_AGG=$(jq -r '
  [.panels[]
    | select(.datasource.uid == "prometheus" and .type == "timeseries")
    | .targets[]
    | select(.legendFormat != null)
    | select(.legendFormat | test("^\\{\\{") | not)
    | select(.expr | test("sum\\(|sum by|histogram_quantile") | not)
    | select(.expr | test("=~") )
  ] | length
' "$F")
assert_eq "$LABEL S3: Prom timeseries with fixed legend all aggregate to 1 series" "0" "$PROM_NO_AGG"

# S4: piechart has per-value color overrides
PIE_OVERRIDES=$(jq -r '[.panels[]|select(.type=="piechart")|.fieldConfig.overrides[]]|length' "$F")
assert_gt "$LABEL S4: piechart has per-value color overrides" 0 "$PIE_OVERRIDES"
PIE_COLOR=$(jq -r '[.panels[]|select(.type=="piechart")][0].fieldConfig.defaults.color.mode' "$F")
assert_eq "$LABEL S4: piechart color mode is palette-classic" "palette-classic" "$PIE_COLOR"

# S11: p7 status code overrides cover expected codes
P7_CODES=$(jq -r '[.panels[]|select(.id==7)][0].fieldConfig.overrides | map(.matcher.options) | sort | join(",")' "$F")
assert_eq "$LABEL S11: p7 has color overrides for 200,401,429,499,504" \
  "200,401,429,499,504" "$P7_CODES"

# S12: p11 bandwidth queries use sum()
P11_EXPRS=$(jq -r '[.panels[]|select(.id==11)][0].targets | map(.expr|test("sum\\(")|if . then "yes" else "no" end)|join(",")' "$F")
assert_eq "$LABEL S12: p11 bandwidth targets both use sum()" "yes,yes" "$P11_EXPRS"

# S14: p4 Error Rate uses ClickHouse datasource
P4_DS=$(jq -r '[.panels[]|select(.id==4)][0].datasource.uid' "$F")
assert_eq "$LABEL S14: p4 Error Rate datasource is clickhouse" "clickhouse" "$P4_DS"

# S15: p4 query uses countIf(status >= 400), $__timeFilter, request_log
P4_SQL=$(jq -r '[.panels[]|select(.id==4)][0].targets[0].rawSql' "$F")
echo "$P4_SQL" | grep -q 'countIf(status >= 400)' && { echo "[PASS] $LABEL S15: p4 uses countIf(status >= 400)"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL S15: p4 missing countIf(status >= 400)"; fail=$((fail+1)); }
echo "$P4_SQL" | grep -q '\$__timeFilter' && { echo "[PASS] $LABEL S15: p4 uses \$__timeFilter"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL S15: p4 missing \$__timeFilter"; fail=$((fail+1)); }
echo "$P4_SQL" | grep -q 'request_log' && { echo "[PASS] $LABEL S15: p4 queries request_log"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL S15: p4 not querying request_log"; fail=$((fail+1)); }

# S17: p4 thresholds are null,1,5
P4_THRESH=$(jq -r '[.panels[]|select(.id==4)][0].fieldConfig.defaults.thresholds.steps | map(.value|if .==null then "null" else tostring end)|join(",")' "$F")
assert_eq "$LABEL S17: p4 thresholds are null,1,5" "null,1,5" "$P4_THRESH"

# S18: p4 target format and queryType
P4_FMT=$(jq -r '[.panels[]|select(.id==4)][0].targets[0].format' "$F")
assert_eq "$LABEL S18: p4 target format is table" "table" "$P4_FMT"
P4_QT=$(jq -r '[.panels[]|select(.id==4)][0].targets[0].queryType' "$F")
assert_eq "$LABEL S18: p4 target queryType is table" "table" "$P4_QT"

# p13: Stream Abort Rate, 2 targets, is_stream=1, aborted
P13_TITLE=$(jq -r '[.panels[]|select(.id==13)][0].title' "$F")
assert_eq "$LABEL: p13 title is Stream Abort Rate by Direction (%)" "Stream Abort Rate by Direction (%)" "$P13_TITLE"
P13_TGT=$(jq '[.panels[]|select(.id==13)][0].targets|length' "$F")
assert_eq "$LABEL: p13 has 2 targets" "2" "$P13_TGT"
P13_STREAM=$(jq '[[.panels[]|select(.id==13)][0].targets[].rawSql|select(.!=null)|select(test("is_stream = 1"))]|length>0' "$F")
assert_eq "$LABEL: p13 filters is_stream = 1" "true" "$P13_STREAM"
P13_ABT=$(jq '[[.panels[]|select(.id==13)][0].targets[].rawSql|select(.!=null)|select(test("aborted"))]|length>0' "$F")
assert_eq "$LABEL: p13 references aborted column" "true" "$P13_ABT"

# p14: Stream Status, 3 targets, labels
P14_TITLE=$(jq -r '[.panels[]|select(.id==14)][0].title' "$F")
assert_eq "$LABEL: p14 title is Stream Status" "Stream Status (completed / client-aborted / provider-aborted)" "$P14_TITLE"
P14_TGT=$(jq '[.panels[]|select(.id==14)][0].targets|length' "$F")
assert_eq "$LABEL: p14 has 3 targets" "3" "$P14_TGT"
P14_LABELS=$(jq -r '[[.panels[]|select(.id==14)][0].targets[].rawSql|select(.!=null)|split("\u0027")|.[1]]|sort|join(",")' "$F")
assert_eq "$LABEL: p14 labels are Client,Completed,Provider" "Client aborted,Completed,Provider aborted" "$P14_LABELS"

# p14 palette: completed/client/provider brand colors
P14_PALETTE=$(jq -r '
  [.panels[]|select(.id==14)][0] as $p14 |
  reduce $p14.fieldConfig.overrides[] as $o ({};
    reduce $o.properties[] as $prop (.;
      if $prop.id == "color" then . + {($o.matcher.options): ($prop.value.fixedColor|ascii_downcase)} else . end
    )
  ) | . as $got |
  {"Completed":"#70c1b3","Client aborted":"#f25f5c","Provider aborted":"#ffe066"} as $exp |
  if $got == $exp then "OK" else "MISMATCH expected=\($exp|tojson) got=\($got|tojson)" end
' "$F")
assert_eq "$LABEL: p14 uses brand palette (completed/client/provider)" "OK" "$P14_PALETTE"

# p10: ASOF LEFT JOIN, u.model, r.upstream_response_time_s
P10_ADOF=$(jq '[[.panels[]|select(.id==10)][0].targets[].rawSql|select(.!=null)|select(test("ASOF LEFT JOIN";"i"))]|length>0' "$F")
assert_eq "$LABEL: p10 uses ASOF LEFT JOIN" "true" "$P10_ADOF"
P10_UMODEL=$(jq '[[.panels[]|select(.id==10)][0].targets[].rawSql|select(.!=null)|select(test("u.model"))]|length>0' "$F")
assert_eq "$LABEL: p10 selects u.model" "true" "$P10_UMODEL"
P10_LAT=$(jq '[[.panels[]|select(.id==10)][0].targets[].rawSql|select(.!=null)|select(test("r.upstream_response_time_s"))]|length>0' "$F")
assert_eq "$LABEL: p10 uses r.upstream_response_time_s" "true" "$P10_LAT"

# Prom panels with key_hash filter: 3 of 5 (p5, p9, p11; p2 and p12 are global)
PROM_KEYHASH=$(jq '[.panels[]|select(.datasource.uid=="prometheus")|select([.targets[].expr?|select(.!=null)|select(test("key_hash"))]|length>0)]|length' "$F")
assert_eq "$LABEL: Prometheus panels with key_hash filter" "3" "$PROM_KEYHASH"

# Cross-dashboard invariant: templating identical across all 3
check_templating_sync

summary "test_dashboard_ops_health.sh"
