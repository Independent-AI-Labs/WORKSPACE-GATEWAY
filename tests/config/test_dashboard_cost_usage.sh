#!/bin/bash
set -euo pipefail

# Structure tests for Dashboard 1: Gateway Cost & Usage
# (conf/grafana/dashboards/gateway-cost-usage.json)
# Panels: p3 Token Usage by Category, p15 Cost Over Time by Model, p8 Model Distribution

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
    _SELF="$SHG_SCRIPT_PATH"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
source "$SCRIPT_DIR/dashboard_assert.sh" || exit 1

F="$COST_USAGE_FILE"
LABEL="cost-usage"

echo "=== Dashboard Structure Tests: Gateway Cost & Usage ==="
echo ""

[ -f "$F" ] || { echo "[FAIL] $LABEL missing: $F"; fail=$((fail+1)); summary "test_dashboard_cost_usage.sh"; }

assert_json_valid "$LABEL: dashboard JSON is valid" "$F"

# Identity
assert_eq "$LABEL: title is Gateway Cost & Usage" "Gateway Cost & Usage" "$(jq -r '.title' "$F")"
assert_eq "$LABEL: uid is gateway-cost-usage" "gateway-cost-usage" "$(jq -r '.uid' "$F")"

# Panel count and datasource split (4 panels, all ClickHouse)
assert_eq "$LABEL: panel count is 4" "4" "$(jq '.panels|length' "$F")"
assert_eq "$LABEL: ClickHouse panels" "4" "$(jq '[.panels[]|select(.datasource.uid=="clickhouse")]|length' "$F")"
assert_eq "$LABEL: Prometheus panels" "0" "$(jq '[.panels[]|select(.datasource.uid=="prometheus")]|length' "$F")"

# Generic structural checks (basics, brand palette, time/refresh, macros, formats)
check_dashboard_basics "$F" "$LABEL"

# p3: 8 unique override matcher names (4 categories + Total + 3 averages)
P3_MATCHERS=$(jq -r '[.panels[]|select(.id==3)][0].fieldConfig.overrides | map(.matcher.options) | sort | join(",")' "$F")
assert_eq "$LABEL S5b: p3 has 8 matcher names (4 categories + Total + 3 averages)" \
  "Cached Tokens,Daily Average,Input Tokens,Monthly Average,Output Tokens,Reasoning Tokens,Total,Weekly Average" "$P3_MATCHERS"

# p3: consolidated single target (was 5 duplicated CTEs), 8 overrides (4 categories + Total + 3 averages)
P3_TARGETS=$(jq '[.panels[]|select(.id==3)][0].targets|length' "$F")
assert_eq "$LABEL: p3 has 1 target" "1" "$P3_TARGETS"
P3_OVERRIDES=$(jq '[.panels[]|select(.id==3)][0].fieldConfig.overrides|length' "$F")
assert_eq "$LABEL: p3 has 8 field overrides" "8" "$P3_OVERRIDES"
P3_SQL=$(jq -r '[.panels[]|select(.id==3)][0].targets[0].rawSql' "$F")
P3_COLS=0
for col in "Input Tokens" "Cached Tokens" "Output Tokens" "Reasoning Tokens" "Total"; do
    printf '%s' "$P3_SQL" | grep -qF "as \"$col\"" && P3_COLS=$((P3_COLS+1))
done
assert_eq "$LABEL: p3 query returns 5 token columns incl. Total" "5" "$P3_COLS"

# p3: numeric columns, no string-formatted values; Total folds spend into token string
# token categories formatted as compact uppercase B/M/K strings; cost as exact "$x.yy"
P3_STR=0
printf '%s' "$P3_SQL" | grep -qE "multiIf" || P3_STR=1
printf '%s' "$P3_SQL" | grep -qF ", 'B')" && printf '%s' "$P3_SQL" | grep -qF ", 'M')" && printf '%s' "$P3_SQL" | grep -qF ", 'K')" || P3_STR=1
assert_eq "$LABEL: p3 token columns use compact B/M/K formatting" "0" "$P3_STR"
printf '%s' "$P3_SQL" | grep -qF "' / \$'" && { echo "[PASS] $LABEL: p3 renders tokens / exact dollars (\$x.yy)"; pass=$((pass+1)); fail_msg=""; } || { echo "[FAIL] $LABEL: p3 missing tokens/dollar formatting"; fail=$((fail+1)); }

# p3: horizontal tiles, Total + averages fill the second row (maxPerRow 4), Total enlarged
P3_ORIENT=$(jq -r '[.panels[]|select(.id==3)][0].options.orientation // "missing"' "$F")
assert_eq "$LABEL: p3 keeps horizontal tiles" "horizontal" "$P3_ORIENT"
P3_MAXROW=$(jq -r '[.panels[]|select(.id==3)][0].options.maxPerRow // "missing"' "$F")
assert_eq "$LABEL: p3 wraps after 4 tiles (Total + averages on the bottom row)" "4" "$P3_MAXROW"
P3_LAST_COLS=$(jq -r '[.panels[]|select(.id==3)][0].targets[0].rawSql' "$F" | grep -o 'as "[^"]*"' | sed 's/as "//; s/"//' | paste -sd, -)
assert_eq "$LABEL: p3 column order puts Total then period averages last" \
  "Input Tokens,Cached Tokens,Output Tokens,Reasoning Tokens,Total,Monthly Average,Weekly Average,Daily Average" "$P3_LAST_COLS"
P3_BIG=$(jq '[ [.panels[]|select(.id==3)][0].fieldConfig.overrides[] | select(.matcher.options == "Total") | .properties[] | select(.id == "textSize") ] | length' "$F")
assert_eq "$LABEL: p3 Total carries a textSize override (enlarged)" "1" "$P3_BIG"

# p3: Total and the period averages combine compact tokens + exact dollars
P3_AVG_SEP=$(printf '%s' "$P3_SQL" | grep -oF "' / \$'" | wc -l | tr -d ' ')
assert_eq "$LABEL: p3 Total + averages render tokens / exact cost (4 columns)" "4" "$P3_AVG_SEP"
P3_AVG_PERIODS=$(printf '%s' "$P3_SQL" | grep -oF 'uniqExact(' | wc -l | tr -d ' ')
assert_eq "$LABEL: p3 averages divide by distinct days/weeks/months" "3" "$P3_AVG_PERIODS"

# p3: stat panel positioned top-left
P3_GRID=$(jq -r '[.panels[]|select(.id==3)][0].gridPos | "y=\(.y),x=\(.x)"' "$F")
assert_eq "$LABEL: p3 positioned top-left (y=0,x=0)" "y=0,x=0" "$P3_GRID"

# p3: stat with >1 target has unique matchers
DUP_MATCHERS=$(jq -r '
  [.panels[]|select(.type=="stat" and (.targets|length>1))|.fieldConfig.overrides|group_by(.matcher.options)|map(select(length>1))|length]|add // 0
' "$F")
assert_eq "$LABEL S5: no stat panel has duplicate override matchers" "0" "$DUP_MATCHERS"

# p15: title, timeseries, sums cost, filters by api_key
P15_TITLE=$(jq -r '[.panels[]|select(.id==15)][0].title' "$F")
assert_eq "$LABEL: p15 title is Cost Over Time by Model (\$)" "Cost Over Time by Model (\$)" "$P15_TITLE"
P15_TYPE=$(jq -r '[.panels[]|select(.id==15)][0].type' "$F")
assert_eq "$LABEL: p15 is timeseries" "timeseries" "$P15_TYPE"
P15_COST=$(jq '[[.panels[]|select(.id==15)][0].targets[].rawSql|select(.!=null)|select(test("sum\\(cost\\)"))]|length>0' "$F")
assert_eq "$LABEL: p15 query sums cost" "true" "$P15_COST"
P15_APIKEY=$(jq '[[.panels[]|select(.id==15)][0].targets[].rawSql|select(.!=null)|select(test("\\$\\{api_key:singlequote\\}"))]|length>0' "$F")
assert_eq "$LABEL: p15 filters by \${api_key:singlequote}" "true" "$P15_APIKEY"

# p8: bargauge, single-table usage_log query (no ASOF JOIN needed), selects model
P8_TYPE=$(jq -r '[.panels[]|select(.id==8)][0].type' "$F")
assert_eq "$LABEL: p8 is bargauge" "bargauge" "$P8_TYPE"
P8_USAGE=$(jq '[[.panels[]|select(.id==8)][0].targets[].rawSql|select(.!=null)|select(test("FROM llm_gateway.usage_log";"i"))]|length>0' "$F")
assert_eq "$LABEL: p8 queries usage_log directly" "true" "$P8_USAGE"
P8_MODEL=$(jq '[[.panels[]|select(.id==8)][0].targets[].rawSql|select(.!=null)|select(test("SELECT model";"i"))]|length>0' "$F")
assert_eq "$LABEL: p8 selects model" "true" "$P8_MODEL"

# p46: Cost by Provider pie (the "where does the money go" split)
P46_TYPE=$(jq -r '[.panels[]|select(.id==46)][0].type // "missing"' "$F")
assert_eq "$LABEL: p46 is piechart" "piechart" "$P46_TYPE"
P46_TITLE=$(jq -r '[.panels[]|select(.id==46)][0].title // "missing"' "$F")
assert_eq "$LABEL: p46 title is Cost by Provider" "Cost by Provider (\$)" "$P46_TITLE"
P46_SQL=$(jq -r '[.panels[]|select(.id==46)][0].targets[0].rawSql // ""' "$F")
printf '%s' "$P46_SQL" | grep -q 'provider_id' && printf '%s' "$P46_SQL" | grep -q 'sum(cost)' && printf '%s' "$P46_SQL" | grep -q 'GROUP BY' && { echo "[PASS] $LABEL: p46 groups cost by provider_id"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p46 missing provider cost aggregation"; fail=$((fail+1)); }
printf '%s' "$P46_SQL" | grep -q '\${api_key:singlequote}' && printf '%s' "$P46_SQL" | grep -q '\${model:singlequote}' && { echo "[PASS] $LABEL: p46 filters by api_key + model"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p46 missing variable filters"; fail=$((fail+1)); }

# Cross-dashboard invariant: templating identical across all 3
check_templating_sync

summary "test_dashboard_cost_usage.sh"
