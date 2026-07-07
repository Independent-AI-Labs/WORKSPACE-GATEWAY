#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DASHBOARD_FILE="$REPO_ROOT/conf/grafana/dashboards/gateway-overview.json"

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
        echo "[FAIL] $desc: expected: $expected, actual: $actual"
        fail=$((fail + 1))
    fi
}

assert_gt() {
    local desc="$1"
    local threshold="$2"
    local actual="$3"
    if [ "$actual" -gt "$threshold" ] 2>/dev/null; then
        echo "[PASS] $desc"
        pass=$((pass + 1))
    else
        echo "[FAIL] $desc: expected > $threshold, got $actual"
        fail=$((fail + 1))
    fi
}

echo "=== Dashboard Structure Tests ==="
echo ""

if [ ! -f "$DASHBOARD_FILE" ]; then
    echo "[FAIL] Dashboard file missing: $DASHBOARD_FILE"
    fail=$((fail + 1))
    echo ""
    echo "test_dashboard_structure.sh: $pass passed, $fail failed"
    exit 1
fi

if ! jq empty "$DASHBOARD_FILE" 2>/dev/null; then
    echo "[FAIL] Dashboard JSON is not valid"
    fail=$((fail + 1))
    echo ""
    echo "test_dashboard_structure.sh: $pass passed, $fail failed"
    exit 1
fi

# S1: ClickHouse bargauge/stat panels use format "table" not numeric
CH_BAD_FORMAT=$(jq -r '
  [.panels[]
    | select(.datasource.uid == "clickhouse")
    | .targets[]
    | select(.format != null)
    | select(.format != "table" and .format != "timeseries")
  ] | length
' "$DASHBOARD_FILE")
assert_eq "S1: No ClickHouse panel uses numeric/legacy format" "0" "$CH_BAD_FORMAT"

# S2: ClickHouse timeseries panels use format "timeseries"
CH_TS_BAD=$(jq -r '
  [.panels[]
    | select(.datasource.uid == "clickhouse" and .type == "timeseries")
    | .targets[]
    | select(.format != "timeseries")
  ] | length
' "$DASHBOARD_FILE")
assert_eq "S2: ClickHouse timeseries panels use format timeseries" "0" "$CH_TS_BAD"

# S3: Prometheus timeseries with fixed-string legendFormat must aggregate to 1 series
# (sum(), sum by(), histogram_quantile, or exact label match all produce a single series)
PROM_NO_AGG=$(jq -r '
  [.panels[]
    | select(.datasource.uid == "prometheus" and .type == "timeseries")
    | .targets[]
    | select(.legendFormat != null)
    | select(.legendFormat | test("^\\{\\{") | not)
    | select(.expr | test("sum\\(|sum by|histogram_quantile") | not)
    | select(.expr | test("=~") )  # has regex label match = could return N series
  ] | length
' "$DASHBOARD_FILE")
assert_eq "S3: Prom timeseries with fixed legend all aggregate to 1 series" "0" "$PROM_NO_AGG"

# S4: Piechart panels must have per-value color overrides (not just thresholds)
PIE_OVERRIDE_COUNT=$(jq -r '
  [.panels[]
    | select(.type == "piechart")
    | .fieldConfig.overrides[]
  ] | length
' "$DASHBOARD_FILE")
assert_gt "S4: Piechart has per-value color overrides" 0 "$PIE_OVERRIDE_COUNT"

PIE_COLOR_MODE=$(jq -r '
  [.panels[] | select(.type == "piechart")][0].fieldConfig.defaults.color.mode
' "$DASHBOARD_FILE")
assert_eq "S4: Piechart color mode is palette-classic (not thresholds)" "palette-classic" "$PIE_COLOR_MODE"

# S5: Stat panels with >1 target must have unique override matchers (not all same)
DUPLICATE_MATCHERS=$(jq -r '
  [.panels[]
    | select(.type == "stat" and (.targets | length > 1))
    | .fieldConfig.overrides
    | group_by(.matcher.options)
    | map(select(length > 1))
    | length
  ] | add // 0
' "$DASHBOARD_FILE")
assert_eq "S5: No stat panel has duplicate override matchers" "0" "$DUPLICATE_MATCHERS"

# S5b: p3 specifically: 5 unique override matcher names
P3_MATCHER_NAMES=$(jq -r '
  [.panels[] | select(.id == 3)][0].fieldConfig.overrides
  | map(.matcher.options) | sort | join(",")
' "$DASHBOARD_FILE")
assert_eq "S5b: p3 has 5 unique matcher names (Cached,Input,Output,Reasoning,Total)" \
  "Cached,Input,Output,Reasoning,Total" "$P3_MATCHER_NAMES"

# S6: Every panel has required fields (title, type, datasource.uid, gridPos, >=1 target)
PANELS_MISSING_FIELDS=$(jq -r '
  [.panels[]
    | select(
        (.title // null) == null or
        (.type // null) == null or
        (.datasource.uid // null) == null or
        (.gridPos // null) == null or
        ((.targets // []) | length) == 0
      )
  ] | length
' "$DASHBOARD_FILE")
assert_eq "S6: All panels have title, type, datasource, gridPos, >=1 target" "0" "$PANELS_MISSING_FIELDS"

# S6b: Every target has a refId
TARGETS_NO_REFID=$(jq -r '
  [.panels[].targets[] | select((.refId // null) == null)] | length
' "$DASHBOARD_FILE")
assert_eq "S6b: All targets have refId" "0" "$TARGETS_NO_REFID"

# S6c: Every ClickHouse target has rawSql; every Prometheus target has expr
CH_NO_SQL=$(jq -r '
  [.panels[] | select(.datasource.uid == "clickhouse")
    | .targets[] | select((.rawSql // null) == null)] | length
' "$DASHBOARD_FILE")
assert_eq "S6c: All ClickHouse targets have rawSql" "0" "$CH_NO_SQL"

PROM_NO_EXPR=$(jq -r '
  [.panels[] | select(.datasource.uid == "prometheus")
    | .targets[] | select((.expr // null) == null)] | length
' "$DASHBOARD_FILE")
assert_eq "S6c: All Prometheus targets have expr" "0" "$PROM_NO_EXPR"

# S7: All hex colors are brand palette
BRAND_HEX=$(jq -r '
  def brand: ["#50514f","#f25f5c","#ffe066","#247ba0","#70c1b3","#a5d0a8","#8cada7","#110b11","#b7990d","#f2f4cb"];
  def is_brand(c): c as $c | brand | index($c | ascii_downcase) != null;
  def is_hex(c): (c | startswith("#"));
  [ .panels[] | . as $p |
    ( .fieldConfig.defaults.color? | select(.mode == "fixed") | .fixedColor? | select(. != null) | . as $c |
      if (is_hex($c) and (is_brand($c) | not)) then "p\($p.id) default \($c | ascii_downcase)" else empty end
    ),
    ( .fieldConfig.defaults.thresholds.steps[]? | .color? | select(. != null) | . as $c |
      if (is_hex($c) and (is_brand($c) | not)) then "p\($p.id) threshold \($c | ascii_downcase)" else empty end
    ),
    ( .fieldConfig.overrides[]? | . as $o | .properties[]? | select(.id == "color") | .value? | select(.mode == "fixed") | .fixedColor? | select(. != null) | . as $c |
      if (is_hex($c) and (is_brand($c) | not)) then "p\($p.id) override[\($o.matcher.options)] \($c | ascii_downcase)" else empty end
    )
  ] as $violations |
  if ($violations | length) == 0 then "OK" else "VIOLATIONS: " + ($violations | join(" | ")) end
' "$DASHBOARD_FILE")
assert_eq "S7: All hex colors are brand palette" "OK" "$BRAND_HEX"

# S8: Dashboard time range and refresh
DASH_FROM=$(jq -r '.time.from' "$DASHBOARD_FILE")
assert_eq "S8: Dashboard time.from is now-24h" "now-24h" "$DASH_FROM"

DASH_TO=$(jq -r '.time.to' "$DASHBOARD_FILE")
assert_eq "S8: Dashboard time.to is now" "now" "$DASH_TO"

DASH_REFRESH=$(jq -r '.refresh' "$DASHBOARD_FILE")
assert_eq "S8: Dashboard refresh is 15s" "15s" "$DASH_REFRESH"

# S9: No conditionalAll macros; no allValue on api_key; model UNIONs both tables
COND_ALL_COUNT=$(jq -r '
  [.panels[].targets[] | (.rawSql // .expr // "") | select(. != null) | select(test("\\$\\$__conditionalAll"))] | length
' "$DASHBOARD_FILE")
assert_eq "S9: No \$__conditionalAll macros" "0" "$COND_ALL_COUNT"

API_KEY_ALLVALUE=$(jq -r '
  [.templating.list[] | select(.name == "api_key")]
  | if length == 0 then "error"
    else (.[0].allValue | if . == null or . == "" then "None" else . end) end
' "$DASHBOARD_FILE")
assert_eq "S9: api_key variable has no allValue" "None" "$API_KEY_ALLVALUE"

MODEL_QUERY=$(jq -r '
  [.templating.list[] | select(.name == "model")]
  | if length == 0 then "error"
    else (.[0].query | ascii_upcase | if test("UNION") then "union" else "single" end) end
' "$DASHBOARD_FILE")
assert_eq "S9: model variable UNIONs both tables" "union" "$MODEL_QUERY"

# S10: Panel count and datasource split
# p4 Error Rate moved from Prometheus to ClickHouse in v34
# (see docs/DASHBOARD-REQUIREMENTS.md section "Why Error Rate uses ClickHouse")
PANEL_COUNT=$(jq '.panels | length' "$DASHBOARD_FILE")
assert_eq "Panel count is 14" "14" "$PANEL_COUNT"

PROM_PANELS=$(jq '[.panels[] | select(.datasource.uid == "prometheus")] | length' "$DASHBOARD_FILE")
assert_eq "Panels using Prometheus datasource" "7" "$PROM_PANELS"

CH_PANELS=$(jq '[.panels[] | select(.datasource.uid == "clickhouse")] | length' "$DASHBOARD_FILE")
assert_eq "Panels using ClickHouse datasource" "7" "$CH_PANELS"

# S11: p7 status code overrides cover expected codes
P7_CODES=$(jq -r '
  [.panels[] | select(.id == 7)][0].fieldConfig.overrides
  | map(.matcher.options) | sort | join(",")
' "$DASHBOARD_FILE")
assert_eq "S11: p7 has color overrides for 200,401,429,499,504" \
  "200,401,429,499,504" "$P7_CODES"

# S12: p11 bandwidth queries use sum() aggregation
P11_EXPRS=$(jq -r '
  [.panels[] | select(.id == 11)][0].targets
  | map(.expr | test("sum\\(") | if . then "yes" else "no" end) | join(",")
' "$DASHBOARD_FILE")
assert_eq "S12: p11 bandwidth targets both use sum()" "yes,yes" "$P11_EXPRS"

# S13: No ClickHouse target has meta/editorType/pluginVersion keys
# These trigger the grafana-clickhouse-datasource builder mode with empty
# columns: [], which produces an empty query and renders nothing.
# See docs/DASHBOARD-REQUIREMENTS.md section 6, requirement 5.
CH_HAS_META=$(jq -r '
  [.panels[] | select(.datasource.uid == "clickhouse")
    | .targets[]
    | select(has("meta") or has("editorType") or has("pluginVersion"))
  ] | length
' "$DASHBOARD_FILE")
assert_eq "S13: No ClickHouse target has meta/editorType/pluginVersion" "0" "$CH_HAS_META"

# S14: p4 Error Rate uses ClickHouse datasource (not Prometheus)
# See docs/DASHBOARD-REQUIREMENTS.md: "Why Error Rate uses ClickHouse, not Prometheus"
P4_DS=$(jq -r '[.panels[] | select(.id == 4)][0].datasource.uid' "$DASHBOARD_FILE")
assert_eq "S14: p4 Error Rate datasource is clickhouse" "clickhouse" "$P4_DS"

# S15: p4 Error Rate query uses countIf(status >= 500) and $__timeFilter
P4_SQL=$(jq -r '[.panels[] | select(.id == 4)][0].targets[0].rawSql' "$DASHBOARD_FILE")
echo "$P4_SQL" | grep -q 'countIf(status >= 500)' && { echo "[PASS] S15: p4 uses countIf(status >= 500)"; pass=$((pass+1)); } || { echo "[FAIL] S15: p4 missing countIf(status >= 500)"; fail=$((fail+1)); }
echo "$P4_SQL" | grep -q '\$__timeFilter' && { echo "[PASS] S15: p4 uses \$__timeFilter"; pass=$((pass+1)); } || { echo "[FAIL] S15: p4 missing \$__timeFilter"; fail=$((fail+1)); }
echo "$P4_SQL" | grep -q 'request_log' && { echo "[PASS] S15: p4 queries request_log"; pass=$((pass+1)); } || { echo "[FAIL] S15: p4 not querying request_log"; fail=$((fail+1)); }

# S16: ClickHouse table panels (bargauge, stat) use format "table"
# ClickHouse timeseries panels use format "timeseries" (covered by S2)
# This catches any panel that uses a numeric format value like 1
CH_TABLE_BAD=$(jq -r '
  [.panels[] | select(.datasource.uid == "clickhouse" and (.type == "bargauge" or .type == "stat"))
    | .targets[] | select(.format != "table")
  ] | length
' "$DASHBOARD_FILE")
assert_eq "S16: ClickHouse bargauge/stat panels use format table" "0" "$CH_TABLE_BAD"

# S17: p4 Error Rate has correct thresholds (0/teal, 1/gold, 5/coral)
P4_THRESHOLDS=$(jq -r '
  [.panels[] | select(.id == 4)][0].fieldConfig.defaults.thresholds.steps
  | map(.value | if . == null then "null" else tostring end) | join(",")
' "$DASHBOARD_FILE")
assert_eq "S17: p4 thresholds are null,1,5" "null,1,5" "$P4_THRESHOLDS"

# S18: p4 has no allValue (shared with S9 but explicit per-panel check)
P4_FORMAT=$(jq -r '[.panels[] | select(.id == 4)][0].targets[0].format' "$DASHBOARD_FILE")
assert_eq "S18: p4 target format is table" "table" "$P4_FORMAT"

P4_QUERYTYPE=$(jq -r '[.panels[] | select(.id == 4)][0].targets[0].queryType' "$DASHBOARD_FILE")
assert_eq "S18: p4 target queryType is table" "table" "$P4_QUERYTYPE"

# S19: Prometheus expression count in dashboard matches prometheus.yaml test file
# This catches stale test data where the dashboard was updated but the yaml was not
PROM_YAML="$REPO_ROOT/tests/integration/queries/prometheus.yaml"
if [ -f "$PROM_YAML" ]; then
    source "$REPO_ROOT/tests/config/yaml_helpers.sh"
    PROM_YAML_COUNT=$(yaml_to_json "$PROM_YAML" | jq 'length' 2>/dev/null || echo "0")
    PROM_DASH_COUNT=$(jq '[.panels[] | select(.datasource.uid == "prometheus") | .targets[]] | length' "$DASHBOARD_FILE")
    assert_eq "S19: prometheus.yaml entries match dashboard Prometheus targets" "$PROM_DASH_COUNT" "$PROM_YAML_COUNT"
else
    rf "S19: prometheus.yaml missing"
fi

# S20: Dashboard version is 34
DASH_VERSION=$(jq -r '.version' "$DASHBOARD_FILE")
assert_eq "S20: Dashboard version is 34" "34" "$DASH_VERSION"

echo ""
echo "test_dashboard_structure.sh: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi
exit 0
