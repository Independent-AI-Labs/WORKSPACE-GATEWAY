#!/bin/bash
set -euo pipefail

# Structure tests for Dashboard 1: Gateway Cost & Usage
# (conf/grafana/dashboards/gateway-cost-usage.json)
# Panels: p3 Token Usage by Category, p15 Cost Over Time by Model, p8 Model Distribution

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/dashboard_assert.sh"

F="$COST_USAGE_FILE"
LABEL="cost-usage"

echo "=== Dashboard Structure Tests: Gateway Cost & Usage ==="
echo ""

[ -f "$F" ] || { echo "[FAIL] $LABEL missing: $F"; fail=$((fail+1)); summary "test_dashboard_cost_usage.sh"; }

assert_json_valid "$LABEL: dashboard JSON is valid" "$F"

# Identity
assert_eq "$LABEL: title is Gateway Cost & Usage" "Gateway Cost & Usage" "$(jq -r '.title' "$F")"
assert_eq "$LABEL: uid is gateway-cost-usage" "gateway-cost-usage" "$(jq -r '.uid' "$F")"

# Panel count and datasource split (3 panels, all ClickHouse)
assert_eq "$LABEL: panel count is 3" "3" "$(jq '.panels|length' "$F")"
assert_eq "$LABEL: ClickHouse panels" "3" "$(jq '[.panels[]|select(.datasource.uid=="clickhouse")]|length' "$F")"
assert_eq "$LABEL: Prometheus panels" "0" "$(jq '[.panels[]|select(.datasource.uid=="prometheus")]|length' "$F")"

# Generic structural checks (basics, brand palette, time/refresh, macros, formats)
check_dashboard_basics "$F" "$LABEL"

# p3: 5 unique override matcher names
P3_MATCHERS=$(jq -r '[.panels[]|select(.id==3)][0].fieldConfig.overrides | map(.matcher.options) | sort | join(",")' "$F")
assert_eq "$LABEL S5b: p3 has 5 matcher names (Cached,Input,Output,Reasoning,Total)" \
  "Cached,Input,Output,Reasoning,Total" "$P3_MATCHERS"

# p3: consolidated single target (was 5 duplicated CTEs), 5 overrides
P3_TARGETS=$(jq '[.panels[]|select(.id==3)][0].targets|length' "$F")
assert_eq "$LABEL: p3 has 1 target" "1" "$P3_TARGETS"
P3_OVERRIDES=$(jq '[.panels[]|select(.id==3)][0].fieldConfig.overrides|length' "$F")
assert_eq "$LABEL: p3 has 5 field overrides" "5" "$P3_OVERRIDES"
P3_COLS=$(jq -r '[.panels[]|select(.id==3)][0].targets[0].rawSql | [test("( as )Total";"i"),test("( as )Input";"i"),test("( as )Cached";"i"),test("( as )Output";"i"),test("( as )Reasoning";"i")] | map(select(.))|length' "$F")
assert_eq "$LABEL: p3 query returns 5 categories" "5" "$P3_COLS"

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

# Cross-dashboard invariant: templating identical across all 3
check_templating_sync

summary "test_dashboard_cost_usage.sh"
