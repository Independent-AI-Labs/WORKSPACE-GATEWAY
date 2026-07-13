#!/bin/bash
set -euo pipefail

# Structure tests for Dashboard 3: Gateway Cost Leaderboard
# (conf/grafana/dashboards/gateway-cost-leaderboard.json)
# Panels: p20 Top Clients, p21 Top Models (stat panels, 10 ranked tiles like p3)
# Top 3 tiles: gold/silver/bronze backgrounds; rest white.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/dashboard_assert.sh"

F="$LEADERBOARD_FILE"
LABEL="cost-leaderboard"

echo "=== Dashboard Structure Tests: Gateway Cost Leaderboard ==="
echo ""

[ -f "$F" ] || { echo "[FAIL] $LABEL missing: $F"; fail=$((fail+1)); summary "test_dashboard_cost_leaderboard.sh"; }

assert_json_valid "$LABEL: dashboard JSON is valid" "$F"

# Identity
assert_eq "$LABEL: title is Gateway Cost Leaderboard" "Gateway Cost Leaderboard" "$(jq -r '.title' "$F")"
assert_eq "$LABEL: uid is gateway-cost-leaderboard" "gateway-cost-leaderboard" "$(jq -r '.uid' "$F")"

# Panel count and datasource split (2 panels, ClickHouse)
assert_eq "$LABEL: panel count is 2" "2" "$(jq '.panels|length' "$F")"
assert_eq "$LABEL: ClickHouse panels" "2" "$(jq '[.panels[]|select(.datasource.uid=="clickhouse")]|length' "$F")"
assert_eq "$LABEL: Prometheus panels" "0" "$(jq '[.panels[]|select(.datasource.uid=="prometheus")]|length' "$F")"

# Generic structural checks
check_dashboard_basics "$F" "$LABEL"

# p20: stat panel (like p3 Token Usage by Category), title, full-width grid
P20_TITLE=$(jq -r '[.panels[]|select(.id==20)][0].title' "$F")
assert_eq "$LABEL: p20 title is Top Clients by Cost & Tokens" "Top Clients by Cost & Tokens" "$P20_TITLE"
P20_TYPE=$(jq -r '[.panels[]|select(.id==20)][0].type' "$F")
assert_eq "$LABEL: p20 is stat panel (like p3)" "stat" "$P20_TYPE"
P20_GRID_W=$(jq -r '[.panels[]|select(.id==20)][0].gridPos.w' "$F")
assert_eq "$LABEL: p20 is full-width (w=24)" "24" "$P20_GRID_W"

# p20: single target (ranked CTE returns all rows; rowsToFields expands to tiles)
P20_TARGET_COUNT=$(jq '[.panels[]|select(.id==20)][0].targets | length' "$F")
assert_eq "$LABEL: p20 has 1 target (ranked CTE)" "1" "$P20_TARGET_COUNT"

# p20: stat panel options match p3 (background_solid fills tile fully)
P20_COLOR_MODE=$(jq -r '[.panels[]|select(.id==20)][0].options.colorMode' "$F")
assert_eq "$LABEL: p20 colorMode is background_solid" "background_solid" "$P20_COLOR_MODE"
P20_TEXT_MODE=$(jq -r '[.panels[]|select(.id==20)][0].options.textMode' "$F")
assert_eq "$LABEL: p20 textMode is value_and_name (like p3)" "value_and_name" "$P20_TEXT_MODE"
P20_ORIENTATION=$(jq -r '[.panels[]|select(.id==20)][0].options.orientation' "$F")
assert_eq "$LABEL: p20 orientation is horizontal (like p3)" "horizontal" "$P20_ORIENTATION"
P20_GRAPH_MODE=$(jq -r '[.panels[]|select(.id==20)][0].options.graphMode' "$F")
assert_eq "$LABEL: p20 graphMode is none (like p3)" "none" "$P20_GRAPH_MODE"

# p20: reduceOptions matches p3 pattern
P20_CALCS=$(jq -r '[.panels[]|select(.id==20)][0].options.reduceOptions.calcs[0]' "$F")
assert_eq "$LABEL: p20 reduceOptions.calcs is lastNotNull (like p3)" "lastNotNull" "$P20_CALCS"
P20_VALUES=$(jq -r '[.panels[]|select(.id==20)][0].options.reduceOptions.values' "$F")
assert_eq "$LABEL: p20 reduceOptions.values is false (like p3)" "false" "$P20_VALUES"

# p20: default color is white (#FFFFFF) for non-medal tiles
P20_DEFAULT_COLOR=$(jq -r '[.panels[]|select(.id==20)][0].fieldConfig.defaults.color.fixedColor' "$F")
assert_eq "$LABEL: p20 default background is white" "#FFFFFF" "$(echo "$P20_DEFAULT_COLOR" | tr '[:lower:]' '[:upper:]')"
P20_DEFAULT_MODE=$(jq -r '[.panels[]|select(.id==20)][0].fieldConfig.defaults.color.mode' "$F")
assert_eq "$LABEL: p20 default color mode is fixed" "fixed" "$P20_DEFAULT_MODE"

# p20: medal colors are baked into SQL via a `Color` column, then mapped to
# field color by the rowsToFields transformer (handlerKey "color"). This avoids
# per-rank field overrides entirely.
P20_SQL=$(jq -r '[.panels[]|select(.id==20)][0].targets[0].rawSql' "$F")
echo "$P20_SQL" | grep -q "row_number() OVER () = 1, '#C9A44C'" && { echo "[PASS] $LABEL: p20 SQL bakes in matte gold (#C9A44C) for rank 1"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p20 missing gold color in SQL"; fail=$((fail+1)); }
echo "$P20_SQL" | grep -q "row_number() OVER () = 2, '#A8A9AD'" && { echo "[PASS] $LABEL: p20 SQL bakes in matte silver (#A8A9AD) for rank 2"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p20 missing silver color in SQL"; fail=$((fail+1)); }
echo "$P20_SQL" | grep -q "row_number() OVER () = 3, '#B07A3C'" && { echo "[PASS] $LABEL: p20 SQL bakes in matte bronze (#B07A3C) for rank 3"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p20 missing bronze color in SQL"; fail=$((fail+1)); }

# p20: rowsToFields transformer maps Color column to field config color
P20_HAS_ROWS_TO_FIELDS=$(jq '[.panels[]|select(.id==20)][0].transformations[] | select(.id=="rowsToFields") | .id' "$F")
assert_eq "$LABEL: p20 uses rowsToFields transformer" '"rowsToFields"' "$P20_HAS_ROWS_TO_FIELDS"
P20_COLOR_MAPPING=$(jq -r '[.panels[]|select(.id==20)][0].transformations[] | select(.id=="rowsToFields") | .options.mappings[] | select(.fieldName=="Color") | .handlerKey' "$F")
assert_eq "$LABEL: p20 maps Color column to color handler" "color" "$P20_COLOR_MAPPING"
P20_NAME_MAPPING=$(jq -r '[.panels[]|select(.id==20)][0].transformations[].options | .mappings[] | select(.fieldName=="name_str") | .handlerKey' "$F")
assert_eq "$LABEL: p20 maps name_str to field.name" "field.name" "$P20_NAME_MAPPING"
P20_VALUE_MAPPING=$(jq -r '[.panels[]|select(.id==20)][0].transformations[] | select(.id=="rowsToFields") | .options.mappings[] | select(.fieldName=="value_str") | .handlerKey' "$F")
assert_eq "$LABEL: p20 maps value_str to field.value" "field.value" "$P20_VALUE_MAPPING"

# p20: no field overrides -- all color comes from the Color column
P20_OVERRIDE_COUNT=$(jq '[.panels[]|select(.id==20)][0].fieldConfig.overrides | length' "$F")
assert_eq "$LABEL: p20 has no field overrides (color from SQL)" "0" "$P20_OVERRIDE_COUNT"

# p20: CTE groups by client, orders by total_cost DESC, limits to 100 in CTE
P20_SQL=$(jq -r '[.panels[]|select(.id==20)][0].targets[0].rawSql' "$F")
echo "$P20_SQL" | grep -q 'GROUP BY client' && { echo "[PASS] $LABEL: p20 CTE groups by client"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p20 missing GROUP BY client"; fail=$((fail+1)); }
echo "$P20_SQL" | grep -q 'ORDER BY total_cost DESC' && { echo "[PASS] $LABEL: p20 CTE orders by total_cost DESC"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p20 missing ORDER BY total_cost DESC"; fail=$((fail+1)); }
echo "$P20_SQL" | grep -q 'LIMIT 100' && { echo "[PASS] $LABEL: p20 CTE limits to 100 rows"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p20 missing LIMIT 100"; fail=$((fail+1)); }
echo "$P20_SQL" | grep -q 'sum(cost)' && { echo "[PASS] $LABEL: p20 sums cost"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p20 missing sum(cost)"; fail=$((fail+1)); }
echo "$P20_SQL" | grep -q 'sum(total_tokens)' && { echo "[PASS] $LABEL: p20 sums total_tokens"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p20 missing sum(total_tokens)"; fail=$((fail+1)); }

# p20: filters by api_key and model (same filter header as other dashboards)
echo "$P20_SQL" | grep -q '\${api_key:singlequote}' && { echo "[PASS] $LABEL: p20 filters by \${api_key:singlequote}"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p20 missing api_key filter"; fail=$((fail+1)); }
echo "$P20_SQL" | grep -q '\${model:singlequote}' && { echo "[PASS] $LABEL: p20 filters by \${model:singlequote}"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p20 missing model filter"; fail=$((fail+1)); }

# p20: identity key matches api_key template variable pattern
echo "$P20_SQL" | grep -q "coalesce(nullIf(key_id,''), nullIf(api_key_id,''), 'unknown')" && { echo "[PASS] $LABEL: p20 identity key matches api_key variable"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p20 identity key mismatch"; fail=$((fail+1)); }

# p20: value format matches p3 (multiIf Mil/K + cost in parens)
echo "$P20_SQL" | grep -q 'multiIf' && { echo "[PASS] $LABEL: p20 uses multiIf for Mil/K formatting (like p3)"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p20 missing multiIf formatting"; fail=$((fail+1)); }
echo "$P20_SQL" | grep -q "' Mil'" && { echo "[PASS] $LABEL: p20 formats millions as Mil (like p3)"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p20 missing Mil format"; fail=$((fail+1)); }
echo "$P20_SQL" | grep -q "' K'" && { echo "[PASS] $LABEL: p20 formats thousands as K (like p3)"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p20 missing K format"; fail=$((fail+1)); }

# p20: value_str alias includes the cost in parens ($...)
echo "$P20_SQL" | grep -q "AS name_str" && { echo "[PASS] $LABEL: p20 aliases name_str"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p20 missing name_str alias"; fail=$((fail+1)); }
echo "$P20_SQL" | grep -q "AS value_str" && { echo "[PASS] $LABEL: p20 aliases value_str"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p20 missing value_str alias"; fail=$((fail+1)); }
echo "$P20_SQL" | grep -q "AS Color" && { echo "[PASS] $LABEL: p20 aliases Color"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p20 missing Color alias"; fail=$((fail+1)); }

# p20: reduces on ALL fields (rowsToFields makes one field per row)
P20_REDUCE_FIELDS=$(jq -r '[.panels[]|select(.id==20)][0].options.reduceOptions.fields' "$F")
assert_eq "$LABEL: p20 reduceOptions.fields matches all rows" "/./" "$P20_REDUCE_FIELDS"

# p21: stat panel (like p20), title, full-width grid below p20
P21_TITLE=$(jq -r '[.panels[]|select(.id==21)][0].title' "$F")
assert_eq "$LABEL: p21 title is Top Models by Cost & Tokens" "Top Models by Cost & Tokens" "$P21_TITLE"
P21_TYPE=$(jq -r '[.panels[]|select(.id==21)][0].type' "$F")
assert_eq "$LABEL: p21 is stat panel (like p20)" "stat" "$P21_TYPE"
P21_GRID_W=$(jq -r '[.panels[]|select(.id==21)][0].gridPos.w' "$F")
assert_eq "$LABEL: p21 is full-width (w=24)" "24" "$P21_GRID_W"
P21_GRID_Y=$(jq -r '[.panels[]|select(.id==21)][0].gridPos.y' "$F")
assert_eq "$LABEL: p21 is stacked below p20 (y=16)" "16" "$P21_GRID_Y"

P21_TARGET_COUNT=$(jq '[.panels[]|select(.id==21)][0].targets | length' "$F")
assert_eq "$LABEL: p21 has 1 target (ranked CTE)" "1" "$P21_TARGET_COUNT"

P21_COLOR_MODE=$(jq -r '[.panels[]|select(.id==21)][0].options.colorMode' "$F")
assert_eq "$LABEL: p21 colorMode is background_solid" "background_solid" "$P21_COLOR_MODE"
P21_TEXT_MODE=$(jq -r '[.panels[]|select(.id==21)][0].options.textMode' "$F")
assert_eq "$LABEL: p21 textMode is value_and_name (like p20)" "value_and_name" "$P21_TEXT_MODE"
P21_ORIENTATION=$(jq -r '[.panels[]|select(.id==21)][0].options.orientation' "$F")
assert_eq "$LABEL: p21 orientation is horizontal (like p20)" "horizontal" "$P21_ORIENTATION"
P21_GRAPH_MODE=$(jq -r '[.panels[]|select(.id==21)][0].options.graphMode' "$F")
assert_eq "$LABEL: p21 graphMode is none (like p20)" "none" "$P21_GRAPH_MODE"

P21_CALCS=$(jq -r '[.panels[]|select(.id==21)][0].options.reduceOptions.calcs[0]' "$F")
assert_eq "$LABEL: p21 reduceOptions.calcs is lastNotNull (like p20)" "lastNotNull" "$P21_CALCS"
P21_VALUES=$(jq -r '[.panels[]|select(.id==21)][0].options.reduceOptions.values' "$F")
assert_eq "$LABEL: p21 reduceOptions.values is false (like p20)" "false" "$P21_VALUES"

P21_DEFAULT_COLOR=$(jq -r '[.panels[]|select(.id==21)][0].fieldConfig.defaults.color.fixedColor' "$F")
assert_eq "$LABEL: p21 default background is white" "#FFFFFF" "$(echo "$P21_DEFAULT_COLOR" | tr '[:lower:]' '[:upper:]')"
P21_DEFAULT_MODE=$(jq -r '[.panels[]|select(.id==21)][0].fieldConfig.defaults.color.mode' "$F")
assert_eq "$LABEL: p21 default color mode is fixed" "fixed" "$P21_DEFAULT_MODE"

P21_SQL=$(jq -r '[.panels[]|select(.id==21)][0].targets[0].rawSql' "$F")
echo "$P21_SQL" | grep -q "row_number() OVER () = 1, '#C9A44C'" && { echo "[PASS] $LABEL: p21 SQL bakes in matte gold (#C9A44C) for rank 1"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p21 missing gold color in SQL"; fail=$((fail+1)); }
echo "$P21_SQL" | grep -q "row_number() OVER () = 2, '#A8A9AD'" && { echo "[PASS] $LABEL: p21 SQL bakes in matte silver (#A8A9AD) for rank 2"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p21 missing silver color in SQL"; fail=$((fail+1)); }
echo "$P21_SQL" | grep -q "row_number() OVER () = 3, '#B07A3C'" && { echo "[PASS] $LABEL: p21 SQL bakes in matte bronze (#B07A3C) for rank 3"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p21 missing bronze color in SQL"; fail=$((fail+1)); }

P21_HAS_ROWS_TO_FIELDS=$(jq '[.panels[]|select(.id==21)][0].transformations[] | select(.id=="rowsToFields") | .id' "$F")
assert_eq "$LABEL: p21 uses rowsToFields transformer" '"rowsToFields"' "$P21_HAS_ROWS_TO_FIELDS"
P21_COLOR_MAPPING=$(jq -r '[.panels[]|select(.id==21)][0].transformations[] | select(.id=="rowsToFields") | .options.mappings[] | select(.fieldName=="Color") | .handlerKey' "$F")
assert_eq "$LABEL: p21 maps Color column to color handler" "color" "$P21_COLOR_MAPPING"
P21_NAME_MAPPING=$(jq -r '[.panels[]|select(.id==21)][0].transformations[].options | .mappings[] | select(.fieldName=="name_str") | .handlerKey' "$F")
assert_eq "$LABEL: p21 maps name_str to field.name" "field.name" "$P21_NAME_MAPPING"
P21_VALUE_MAPPING=$(jq -r '[.panels[]|select(.id==21)][0].transformations[] | select(.id=="rowsToFields") | .options.mappings[] | select(.fieldName=="value_str") | .handlerKey' "$F")
assert_eq "$LABEL: p21 maps value_str to field.value" "field.value" "$P21_VALUE_MAPPING"

P21_OVERRIDE_COUNT=$(jq '[.panels[]|select(.id==21)][0].fieldConfig.overrides | length' "$F")
assert_eq "$LABEL: p21 has no field overrides (color from SQL)" "0" "$P21_OVERRIDE_COUNT"

echo "$P21_SQL" | grep -q 'GROUP BY model_name' && { echo "[PASS] $LABEL: p21 CTE groups by model_name"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p21 missing GROUP BY model_name"; fail=$((fail+1)); }
echo "$P21_SQL" | grep -q 'ORDER BY total_cost DESC' && { echo "[PASS] $LABEL: p21 CTE orders by total_cost DESC"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p21 missing ORDER BY total_cost DESC"; fail=$((fail+1)); }
echo "$P21_SQL" | grep -q 'LIMIT 100' && { echo "[PASS] $LABEL: p21 CTE limits to 100 rows"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p21 missing LIMIT 100"; fail=$((fail+1)); }
echo "$P21_SQL" | grep -q 'sum(cost)' && { echo "[PASS] $LABEL: p21 sums cost"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p21 missing sum(cost)"; fail=$((fail+1)); }
echo "$P21_SQL" | grep -q 'sum(total_tokens)' && { echo "[PASS] $LABEL: p21 sums total_tokens"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p21 missing sum(total_tokens)"; fail=$((fail+1)); }
echo "$P21_SQL" | grep -q "model != ''" && { echo "[PASS] $LABEL: p21 excludes empty model"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p21 missing model != '' filter"; fail=$((fail+1)); }

echo "$P21_SQL" | grep -q '\${api_key:singlequote}' && { echo "[PASS] $LABEL: p21 filters by \${api_key:singlequote}"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p21 missing api_key filter"; fail=$((fail+1)); }
echo "$P21_SQL" | grep -q '\${model:singlequote}' && { echo "[PASS] $LABEL: p21 filters by \${model:singlequote}"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p21 missing model filter"; fail=$((fail+1)); }

echo "$P21_SQL" | grep -q 'multiIf' && { echo "[PASS] $LABEL: p21 uses multiIf for Mil/K formatting (like p20)"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p21 missing multiIf formatting"; fail=$((fail+1)); }
echo "$P21_SQL" | grep -q "' Mil'" && { echo "[PASS] $LABEL: p21 formats millions as Mil (like p20)"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p21 missing Mil format"; fail=$((fail+1)); }
echo "$P21_SQL" | grep -q "' K'" && { echo "[PASS] $LABEL: p21 formats thousands as K (like p20)"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p21 missing K format"; fail=$((fail+1)); }

echo "$P21_SQL" | grep -q "AS name_str" && { echo "[PASS] $LABEL: p21 aliases name_str"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p21 missing name_str alias"; fail=$((fail+1)); }
echo "$P21_SQL" | grep -q "AS value_str" && { echo "[PASS] $LABEL: p21 aliases value_str"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p21 missing value_str alias"; fail=$((fail+1)); }
echo "$P21_SQL" | grep -q "AS Color" && { echo "[PASS] $LABEL: p21 aliases Color"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p21 missing Color alias"; fail=$((fail+1)); }

P21_REDUCE_FIELDS=$(jq -r '[.panels[]|select(.id==21)][0].options.reduceOptions.fields' "$F")
assert_eq "$LABEL: p21 reduceOptions.fields matches all rows" "/./" "$P21_REDUCE_FIELDS"

# Cross-dashboard invariant: templating identical across all 3
check_templating_sync

summary "test_dashboard_cost_leaderboard.sh"
