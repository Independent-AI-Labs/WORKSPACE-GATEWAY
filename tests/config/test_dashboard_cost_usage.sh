#!/bin/bash
set -euo pipefail

# Structure tests for Dashboard 1: Gateway Cost & Usage
# (conf/grafana/dashboards/gateway-cost-usage.json)
# Panels: p3 Token Usage by Category, p15 Cost Over Time, p8 Model Distribution,
#         p46 Provider Breakdown pie

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
# token categories are compact uppercase B/M/K strings; cost is compact K/M/B money
# (2-decimal, matching the dashboard's Grafana-rendered currency), joined by a middot
P3_STR=0
printf '%s' "$P3_SQL" | grep -qE "multiIf" || P3_STR=1
printf '%s' "$P3_SQL" | grep -qF ", 'B')" && printf '%s' "$P3_SQL" | grep -qF ", 'M')" && printf '%s' "$P3_SQL" | grep -qF ", 'K')" || P3_STR=1
assert_eq "$LABEL: p3 token columns use compact B/M/K formatting" "0" "$P3_STR"
printf '%s' "$P3_SQL" | grep -qF "' · \$'" && { echo "[PASS] $LABEL: p3 joins tokens and cost with a middot"; pass=$((pass+1)); fail_msg=""; } || { echo "[FAIL] $LABEL: p3 missing tokens middot cost separator"; fail=$((fail+1)); }
printf '%s' "$P3_SQL" | grep -qF "printf('%.2f'," && { echo "[PASS] $LABEL: p3 costs abbreviate K/M/B like the dashboard currency"; pass=$((pass+1)); fail_msg=""; } || { echo "[FAIL] $LABEL: p3 costs not K/M/B-abbreviated"; fail=$((fail+1)); }

# p3: horizontal tiles, Total + averages fill the second row (maxPerRow 4), title text enlarged
P3_ORIENT=$(jq -r '[.panels[]|select(.id==3)][0].options.orientation // "missing"' "$F")
assert_eq "$LABEL: p3 keeps horizontal tiles" "horizontal" "$P3_ORIENT"
P3_MAXROW=$(jq -r '[.panels[]|select(.id==3)][0].options.maxPerRow // "missing"' "$F")
assert_eq "$LABEL: p3 wraps after 4 tiles (Total + averages on the bottom row)" "4" "$P3_MAXROW"
P3_LAST_COLS=$(jq -r '[.panels[]|select(.id==3)][0].targets[0].rawSql' "$F" | grep -o 'as "[^"]*"' | sed 's/as "//; s/"//' | paste -sd, -)
assert_eq "$LABEL: p3 column order puts Total then period averages last" \
  "Input Tokens,Cached Tokens,Output Tokens,Reasoning Tokens,Total,Monthly Average,Weekly Average,Daily Average" "$P3_LAST_COLS"
P3_TITLE_SIZE=$(jq -r '[.panels[]|select(.id==3)][0].options.text.titleSize // "missing"' "$F")
assert_eq "$LABEL: p3 stat titles are enlarged (text.titleSize)" "16" "$P3_TITLE_SIZE"
P3_VALUE_SIZE=$(jq -r '[.panels[]|select(.id==3)][0].options.text.valueSize // "missing"' "$F")
assert_eq "$LABEL: p3 stat values stay pinned (text.valueSize)" "18.5" "$P3_VALUE_SIZE"

# p3: Total and the period averages combine compact tokens + compact K/M/B cost
P3_AVG_SEP=$(printf '%s' "$P3_SQL" | grep -oF "' · \$'" | wc -l | tr -d ' ')
assert_eq "$LABEL: p3 Total + averages render tokens middot cost (4 columns)" "4" "$P3_AVG_SEP"
P3_PROJECTS=$(printf '%s' "$P3_SQL" | grep -oF 'elapsed_days' | wc -l | tr -d ' ')
assert_eq "$LABEL: p3 averages project the range total (run-rate, elapsed_days)" "7" "$P3_PROJECTS"
P3_FROMTIME=$(printf '%s' "$P3_SQL" | grep -cF '$__fromTime')
P3_TOTIME=$(printf '%s' "$P3_SQL" | grep -cF 'toDayOfMonth(toLastDayOfMonth(toDate($__toTime)))')
assert_eq "$LABEL: p3 run-rate uses Grafana range bounds + calendar month" "1/1" "$P3_FROMTIME/$P3_TOTIME"

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
assert_eq "$LABEL: p15 title is Cost Over Time" "Cost Over Time" "$P15_TITLE"
P15_TYPE=$(jq -r '[.panels[]|select(.id==15)][0].type' "$F")
assert_eq "$LABEL: p15 is timeseries" "timeseries" "$P15_TYPE"
P15_COST=$(jq '[[.panels[]|select(.id==15)][0].targets[].rawSql|select(.!=null)|select(test("sum\\(cost\\)"))]|length>0' "$F")
assert_eq "$LABEL: p15 query sums cost" "true" "$P15_COST"
P15_APIKEY=$(jq '[[.panels[]|select(.id==15)][0].targets[].rawSql|select(.!=null)|select(test("\\$\\{api_key:singlequote\\}"))]|length>0' "$F")
assert_eq "$LABEL: p15 filters by \${api_key:singlequote}" "true" "$P15_APIKEY"

# p8: treemap of model token volume (colorless; spend in the tooltip), drawn
# by the in-repo gateway-treemap plugin with min/max tile-area constraints.
P8_TYPE=$(jq -r '[.panels[]|select(.id==8)][0].type' "$F")
assert_eq "$LABEL: p8 uses the custom gateway-treemap panel" "gateway-treemap" "$P8_TYPE"
P8_USAGE=$(jq '[[.panels[]|select(.id==8)][0].targets[].rawSql|select(.!=null)|select(test("FROM llm_gateway.usage_log";"i"))]|length>0' "$F")
assert_eq "$LABEL: p8 queries usage_log directly" "true" "$P8_USAGE"
P8_MODEL=$(jq '[[.panels[]|select(.id==8)][0].targets[].rawSql|select(.!=null)|select(test("GROUP BY model";"i"))]|length>0' "$F")
assert_eq "$LABEL: p8 groups by model" "true" "$P8_MODEL"
P8_COLOR=$(jq '[[.panels[]|select(.id==8)][0].targets[].rawSql|select(.!=null)|select(test("model_color_map";"i"))]|length>0' "$F")
assert_eq "$LABEL: p8 no longer joins the model color map" "false" "$P8_COLOR"
P8_DIMS=$(jq -r '[.panels[]|select(.id==8)][0].options|"\(.textField) \(.sizeField)"' "$F")
assert_eq "$LABEL: p8 labels by model, sizes by tokens" "model tokens" "$P8_DIMS"
P8_MIN=$(jq -r '[.panels[]|select(.id==8)][0].options.minTileArea' "$F")
assert_eq "$LABEL: p8 enforces a minimum tile area" "1200" "$P8_MIN"
P8_MAX=$(jq -r '[.panels[]|select(.id==8)][0].options.maxTileArea' "$F")
assert_eq "$LABEL: p8 enforces a maximum tile area" "60000" "$P8_MAX"
P8_OTHER=$(jq -r '[.panels[]|select(.id==8)][0].options.otherLabel' "$F")
assert_eq "$LABEL: p8 labels the overflow tile" "Other models" "$P8_OTHER"
P8_CARD=$(jq -r '[.panels[]|select(.id==8)][0].options.cardTemplate // ""' "$F")
assert_eq "$LABEL: p8 uses the built-in measured tile face (no card template)" "" "$P8_CARD"
P8_TIP=$(jq -r '[.panels[]|select(.id==8)][0].options.tooltipTemplate // ""' "$F")
printf '%s' "$P8_TIP" | grep -q '{{fields.cost}}' && printf '%s' "$P8_TIP" | grep -q '{{percent}}' && { echo "[PASS] $LABEL: p8 tooltip templates spend + share"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p8 tooltip missing fields.cost/percent"; fail=$((fail+1)); }
printf '%s' "$P8_TIP" | grep -q 'row(s)' && { echo "[FAIL] $LABEL: p8 tooltip still shows the useless row/area line"; fail=$((fail+1)); } || { echo "[PASS] $LABEL: p8 tooltip dropped the row/area line"; pass=$((pass+1)); }
P8_SQL=$(jq -r '[.panels[]|select(.id==8)][0].targets[0].rawSql // ""' "$F")
printf '%s' "$P8_SQL" | grep -q 'model' && printf '%s' "$P8_SQL" | grep -q 'tokens' && printf '%s' "$P8_SQL" | grep -q 'AS cost' && { echo "[PASS] $LABEL: p8 returns model/tokens/cost"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p8 missing model/tokens/cost"; fail=$((fail+1)); }
P8_FIXED=$(jq -r '[.panels[]|select(.id==8)][0].fieldConfig.defaults.color.fixedColor' "$F")
assert_eq "$LABEL: p8 tiles render in a single brand color" "#247ba0" "$P8_FIXED"
P8_UNIT=$(jq -r '[.panels[]|select(.id==8)][0].fieldConfig.defaults.unit' "$F")
assert_eq "$LABEL: p8 token size renders compact (short)" "short" "$P8_UNIT"

# p46: Provider Breakdown donut (spend share by provider)
P46_TYPE=$(jq -r '[.panels[]|select(.id==46)][0].type // "missing"' "$F")
assert_eq "$LABEL: p46 is piechart" "piechart" "$P46_TYPE"
P46_TITLE=$(jq -r '[.panels[]|select(.id==46)][0].title // "missing"' "$F")
assert_eq "$LABEL: p46 title is Provider Breakdown" "Provider Breakdown (\$)" "$P46_TITLE"
P46_SQL=$(jq -r '[.panels[]|select(.id==46)][0].targets[0].rawSql // ""' "$F")
printf '%s' "$P46_SQL" | grep -q 'provider_id' && printf '%s' "$P46_SQL" | grep -q 'sum(cost)' && printf '%s' "$P46_SQL" | grep -q 'GROUP BY' && { echo "[PASS] $LABEL: p46 groups spend by provider_id"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p46 missing provider aggregation"; fail=$((fail+1)); }
printf '%s' "$P46_SQL" | grep -q '\${api_key:singlequote}' && printf '%s' "$P46_SQL" | grep -q '\${model:singlequote}' && { echo "[PASS] $LABEL: p46 filters by api_key + model"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p46 missing variable filters"; fail=$((fail+1)); }
P46_RTF=$(jq -r '[.panels[]|select(.id==46)][0].transformations[]?|select(.id=="rowsToFields")|.options.mappings|map(.handlerKey)|join(",")' "$F")
assert_eq "$LABEL: p46 binds provider name + spend (no explicit color)" "field.name,field.value" "$P46_RTF"
P46_PALETTE=$(jq -r '[.panels[]|select(.id==46)][0].fieldConfig.defaults.color.mode' "$F")
assert_eq "$LABEL: p46 lets Grafana palette the slices" "palette-classic" "$P46_PALETTE"
P46_LEGEND=$(jq -r '[.panels[]|select(.id==46)][0].options.legend.showLegend' "$F")
assert_eq "$LABEL: p46 shows the legend" "true" "$P46_LEGEND"
P46_LABELS=$(jq '[.panels[]|select(.id==46)][0].options.displayLabels|length' "$F")
assert_eq "$LABEL: p46 hides pie labels" "0" "$P46_LABELS"
printf '%s' "$P46_SQL" | grep -q 'AS name_str' && printf '%s' "$P46_SQL" | grep -q 'AS value' && { echo "[PASS] $LABEL: p46 tooltip carries provider + requests + tokens"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p46 missing name_str/value"; fail=$((fail+1)); }

# Cross-dashboard invariant: templating identical across all 3
check_templating_sync

summary "test_dashboard_cost_usage.sh"
