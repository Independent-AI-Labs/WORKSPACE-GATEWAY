#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/yaml_helpers.sh"

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

summary() {
    echo ""
    echo "test_grafana_provisioning.sh: $pass passed, $fail failed"
    if [ "$fail" -gt 0 ]; then
        exit 1
    fi
}

# ── datasource provisioning YAML ──────────────────────────────────────

DS_FILE="$REPO_ROOT/conf/grafana/provisioning/datasources/datasources.yml"

if [ ! -f "$DS_FILE" ]; then
    echo "[FAIL] Datasource provisioning file missing: $DS_FILE"
    fail=$((fail + 1))
    summary
fi

assert_eq "Datasources YAML exists" "ok" "ok"

DS_JSON=$(yaml_to_json "$DS_FILE")

DS_COUNT=$(echo "$DS_JSON" | jq '.datasources | length')
assert_eq "Two datasources defined" "2" "$DS_COUNT"

HAS_PROMETHEUS=$(echo "$DS_JSON" | jq '[.datasources[] | select(.name == "Prometheus" and .type == "prometheus")] | length')
assert_eq "Prometheus datasource present" "1" "$HAS_PROMETHEUS"

PROM_URL=$(echo "$DS_JSON" | jq -r '.datasources[] | select(.name == "Prometheus") | .url')
assert_eq "Prometheus URL points to prometheus:9090" "http://prometheus:9090" "$PROM_URL"

PROM_DEFAULT=$(echo "$DS_JSON" | jq -r '.datasources[] | select(.name == "Prometheus") | .isDefault')
assert_eq "Prometheus is default datasource" "true" "$PROM_DEFAULT"

HAS_CLICKHOUSE=$(echo "$DS_JSON" | jq '[.datasources[] | select(.name == "ClickHouse" and .type == "grafana-clickhouse-datasource")] | length')
assert_eq "ClickHouse datasource present" "1" "$HAS_CLICKHOUSE"

CH_HOST=$(echo "$DS_JSON" | jq -r '.datasources[] | select(.name == "ClickHouse") | .jsonData.host')
assert_eq "ClickHouse host is clickhouse" "clickhouse" "$CH_HOST"

CH_PORT=$(echo "$DS_JSON" | jq -r '.datasources[] | select(.name == "ClickHouse") | .jsonData.port')
assert_eq "ClickHouse port is 9000 (native)" "9000" "$CH_PORT"

CH_PROTOCOL=$(echo "$DS_JSON" | jq -r '.datasources[] | select(.name == "ClickHouse") | .jsonData.protocol')
assert_eq "ClickHouse protocol is native" "native" "$CH_PROTOCOL"

CH_DB=$(echo "$DS_JSON" | jq -r '.datasources[] | select(.name == "ClickHouse") | .jsonData.defaultDatabase')
assert_eq "ClickHouse default database is llm_gateway" "llm_gateway" "$CH_DB"

# ── dashboard provisioning YAML ───────────────────────────────────────

DASH_PROVIDER_FILE="$REPO_ROOT/conf/grafana/provisioning/dashboards/dashboards.yml"

if [ ! -f "$DASH_PROVIDER_FILE" ]; then
    echo "[FAIL] Dashboard provisioning file missing: $DASH_PROVIDER_FILE"
    fail=$((fail + 1))
    summary
fi

assert_eq "Dashboard provider YAML exists" "ok" "ok"

DASH_JSON=$(yaml_to_json "$DASH_PROVIDER_FILE")

PROVIDER_NAME=$(echo "$DASH_JSON" | jq -r '.providers[0].name')
assert_eq "Dashboard provider name is gateway-dashboards" "gateway-dashboards" "$PROVIDER_NAME"

PROVIDER_PATH=$(echo "$DASH_JSON" | jq -r '.providers[0].options.path')
assert_eq "Dashboard provider path is /var/lib/grafana/dashboards" "/var/lib/grafana/dashboards" "$PROVIDER_PATH"

# ── dashboard JSON (3 dashboards) ─────────────────────────────────────

DASH_DIR="$REPO_ROOT/conf/grafana/dashboards"
COST_USAGE_FILE="$DASH_DIR/gateway-cost-usage.json"
OPS_HEALTH_FILE="$DASH_DIR/gateway-ops-health.json"
LEADERBOARD_FILE="$DASH_DIR/gateway-cost-leaderboard.json"

for df in "$COST_USAGE_FILE" "$OPS_HEALTH_FILE" "$LEADERBOARD_FILE"; do
    if [ ! -f "$df" ]; then
        echo "[FAIL] Dashboard JSON missing: $df"
        fail=$((fail + 1))
        summary
    fi
    if ! jq empty "$df" 2>/dev/null; then
        echo "[FAIL] Dashboard JSON not valid: $df"
        fail=$((fail + 1))
        summary
    fi
done

assert_eq "All 3 dashboard JSON files exist and are valid" "ok" "ok"

# ── Dashboard 1: Gateway Cost & Usage ─────────────────────────────────

CU_TITLE=$(jq -r '.title' "$COST_USAGE_FILE")
assert_eq "Cost & Usage title" "Gateway Cost & Usage" "$CU_TITLE"

CU_UID=$(jq -r '.uid' "$COST_USAGE_FILE")
assert_eq "Cost & Usage uid" "gateway-cost-usage" "$CU_UID"

CU_PANELS=$(jq '.panels | length' "$COST_USAGE_FILE")
assert_eq "Cost & Usage has 3 panels" "3" "$CU_PANELS"

CU_CH=$(jq '[.panels[] | select(.datasource.uid == "clickhouse")] | length' "$COST_USAGE_FILE")
assert_eq "Cost & Usage ClickHouse panels" "3" "$CU_CH"

# ── Dashboard 2: Gateway Operations & Health ──────────────────────────

OH_TITLE=$(jq -r '.title' "$OPS_HEALTH_FILE")
assert_eq "Ops & Health title" "Gateway Operations & Health" "$OH_TITLE"

OH_UID=$(jq -r '.uid' "$OPS_HEALTH_FILE")
assert_eq "Ops & Health uid" "gateway-ops-health" "$OH_UID"

OH_PANELS=$(jq '.panels | length' "$OPS_HEALTH_FILE")
assert_eq "Ops & Health has 11 panels" "11" "$OH_PANELS"

OH_PROM=$(jq '[.panels[] | select(.datasource.uid == "prometheus")] | length' "$OPS_HEALTH_FILE")
assert_eq "Ops & Health Prometheus panels" "5" "$OH_PROM"

OH_CH=$(jq '[.panels[] | select(.datasource.uid == "clickhouse")] | length' "$OPS_HEALTH_FILE")
assert_eq "Ops & Health ClickHouse panels" "6" "$OH_CH"

# ── Dashboard 3: Gateway Cost Leaderboard ─────────────────────────────

LB_TITLE=$(jq -r '.title' "$LEADERBOARD_FILE")
assert_eq "Cost Leaderboard title" "Gateway Cost Leaderboard" "$LB_TITLE"

LB_UID=$(jq -r '.uid' "$LEADERBOARD_FILE")
assert_eq "Cost Leaderboard uid" "gateway-cost-leaderboard" "$LB_UID"

LB_PANELS=$(jq '.panels | length' "$LEADERBOARD_FILE")
assert_eq "Cost Leaderboard has 2 panels" "2" "$LB_PANELS"

# ── Total panel count across all 3 dashboards (14 original + 2 leaderboard = 16) ──

TOTAL_PANELS=$((CU_PANELS + OH_PANELS + LB_PANELS))
assert_eq "Total panels across 3 dashboards" "16" "$TOTAL_PANELS"

# ── Templating identical across all 3 dashboards (shared filter header) ──

T_CU=$(jq -c '.templating' "$COST_USAGE_FILE")
T_OH=$(jq -c '.templating' "$OPS_HEALTH_FILE")
T_LB=$(jq -c '.templating' "$LEADERBOARD_FILE")
if [ "$T_CU" = "$T_OH" ] && [ "$T_OH" = "$T_LB" ]; then
    echo "[PASS] Templating identical across all 3 dashboards"
    pass=$((pass + 1))
else
    echo "[FAIL] Templating differs across dashboards"
    fail=$((fail + 1))
fi

# ── p3 Token Usage stat: 5 field overrides, 5 targets (in cost-usage) ──

P3_OVERRIDES=$(jq '[.panels[] | select(.id == 3)][0].fieldConfig.overrides | length' "$COST_USAGE_FILE")
assert_eq "p3 has 5 field overrides (Total, Input, Cached, Output, Reasoning)" "5" "$P3_OVERRIDES"

P3_TARGETS=$(jq '[.panels[] | select(.id == 3)][0].targets | length' "$COST_USAGE_FILE")
assert_eq "p3 has 1 target (consolidated CTE)" "1" "$P3_TARGETS"

# ── p16 and p17 removed (Cost by Source panels) ──────────────────────

P16_EXISTS=$(jq '[.panels[] | select(.id == 16)] | length' "$OPS_HEALTH_FILE")
assert_eq "p16 panel removed" "0" "$P16_EXISTS"

P17_EXISTS=$(jq '[.panels[] | select(.id == 17)] | length' "$OPS_HEALTH_FILE")
assert_eq "p17 panel removed" "0" "$P17_EXISTS"

# ── prometheus config ─────────────────────────────────────────────────

PROM_FILE="$REPO_ROOT/conf/prometheus.yml"

if [ ! -f "$PROM_FILE" ]; then
    echo "[FAIL] Prometheus config missing: $PROM_FILE"
    fail=$((fail + 1))
    summary
fi

assert_eq "Prometheus config exists" "ok" "ok"

PROM_JSON=$(yaml_to_json "$PROM_FILE")

SCRAPE_COUNT=$(echo "$PROM_JSON" | jq '.scrape_configs | length')
assert_eq "Two scrape configs" "2" "$SCRAPE_COUNT"

HAS_APISIX_JOB=$(echo "$PROM_JSON" | jq '[.scrape_configs[] | select(.job_name == "gateway-apisix")] | length')
assert_eq "Has gateway-apisix scrape job" "1" "$HAS_APISIX_JOB"

APISIX_TARGET=$(echo "$PROM_JSON" | jq -r '.scrape_configs[] | select(.job_name == "gateway-apisix") | .static_configs[0].targets[0]')
assert_eq "APISIX scrape target is apisix:9100" "apisix:9100" "$APISIX_TARGET"

APISIX_METRICS_PATH=$(echo "$PROM_JSON" | jq -r '.scrape_configs[] | select(.job_name == "gateway-apisix") | .metrics_path')
assert_eq "APISIX metrics path correct" "/apisix/prometheus/metrics" "$APISIX_METRICS_PATH"

# ── variable: api_key has NO allValue (Grafana expands to all values) ──
# (templating is identical across all 3 dashboards; check cost-usage as canonical)

API_KEY_ALLVALUE=$(jq -r '[.templating.list[] | select(.name == "api_key")] | if length == 0 then "None" else (.[0].allValue | if . == null then "None" else . end) end' "$COST_USAGE_FILE")
assert_eq "api_key variable has no allValue (Grafana expands)" "None" "$API_KEY_ALLVALUE"

NO_PROM_VAR=$(jq '[.templating.list[] | select(.name == "api_key_prom")] | length' "$COST_USAGE_FILE")
assert_eq "No api_key_prom variable (single var for CH+Prom)" "0" "$NO_PROM_VAR"

# ── No $__conditionalAll macros in any dashboard ──────────────────────

COND_ALL_TOTAL=0
for df in "$COST_USAGE_FILE" "$OPS_HEALTH_FILE" "$LEADERBOARD_FILE"; do
    c=$(jq '[.panels[].targets[].rawSql | select(. != null) | select(test("\\$\\$__conditionalAll"))] | length' "$df")
    COND_ALL_TOTAL=$((COND_ALL_TOTAL + c))
done
assert_eq "No \$__conditionalAll macros in any dashboard" "0" "$COND_ALL_TOTAL"

# ── ClickHouse panels use \${api_key:singlequote} directly ────────────
# Original 9 CH panels (now 3 in cost-usage + 6 in ops-health) + 2 in leaderboard = 11

CH_APIKEY_TOTAL=0
for df in "$COST_USAGE_FILE" "$OPS_HEALTH_FILE" "$LEADERBOARD_FILE"; do
    c=$(jq '[.panels[] | select(.datasource.uid == "clickhouse") | select([.targets[].rawSql? | select(. != null) | select(test("\\$\\{api_key:singlequote\\}"))] | length > 0)] | length' "$df")
    CH_APIKEY_TOTAL=$((CH_APIKEY_TOTAL + c))
done
assert_eq "ClickHouse panels with \${api_key:singlequote} (all 3 dashboards)" "11" "$CH_APIKEY_TOTAL"

# ── p3 Token Usage stat: 5 tiles, one per category (in cost-usage) ────

P3_TITLE=$(jq -r '[.panels[] | select(.id == 3)][0].title' "$COST_USAGE_FILE")
assert_eq "p3 title is Token Usage by Category" "Token Usage by Category" "$P3_TITLE"

P3_TYPE=$(jq -r '[.panels[] | select(.id == 3)][0].type' "$COST_USAGE_FILE")
assert_eq "p3 is a stat panel" "stat" "$P3_TYPE"

P3_TARGET_COUNT=$(jq '[.panels[] | select(.id == 3)][0].targets | length' "$COST_USAGE_FILE")
assert_eq "p3 Token Usage has 1 target (consolidated CTE)" "1" "$P3_TARGET_COUNT"

P3_HAS_COST=$(jq '[[.panels[] | select(.id == 3)][0].targets[].rawSql | select(. != null) | select(test("cost"))] | length > 0' "$COST_USAGE_FILE")
assert_eq "p3 queries reference cost" "true" "$P3_HAS_COST"

P3_HAS_5_CATEGORIES=$(jq -r '[.panels[] | select(.id == 3)][0].targets[0].rawSql | [test("( as )Total";"i"),test("( as )Input";"i"),test("( as )Cached";"i"),test("( as )Output";"i"),test("( as )Reasoning";"i")] | map(select(.)) | length' "$COST_USAGE_FILE")
assert_eq "p3 has 5 categories (Total + Input + Cached + Output + Reasoning)" "5" "$P3_HAS_5_CATEGORIES"

P3_OVERRIDES=$(jq '[.panels[] | select(.id == 3)][0].fieldConfig.overrides | length' "$COST_USAGE_FILE")
assert_eq "p3 has 5 field overrides (Total, Input, Cached, Output, Reasoning)" "5" "$P3_OVERRIDES"

# ── p15 Cost Over Time by Model (in cost-usage) ───────────────────────

P15_TITLE=$(jq -r '[.panels[] | select(.id == 15)][0].title' "$COST_USAGE_FILE")
assert_eq "p15 title is Cost Over Time" "Cost Over Time by Model ($)" "$P15_TITLE"

P15_TYPE=$(jq -r '[.panels[] | select(.id == 15)][0].type' "$COST_USAGE_FILE")
assert_eq "p15 is a timeseries" "timeseries" "$P15_TYPE"

P15_HAS_COST=$(jq '[[.panels[] | select(.id == 15)][0].targets[].rawSql | select(. != null) | select(test("sum\\(cost\\)"))] | length > 0' "$COST_USAGE_FILE")
assert_eq "p15 query sums cost" "true" "$P15_HAS_COST"

P15_HAS_APIKEY=$(jq '[[.panels[] | select(.id == 15)][0].targets[].rawSql | select(. != null) | select(test("\\$\\{api_key:singlequote\\}"))] | length > 0' "$COST_USAGE_FILE")
assert_eq "p15 filters by \${api_key:singlequote}" "true" "$P15_HAS_APIKEY"

# ── p3 should be top-left (y=0, x=0) per value-interest order ─────────

P3_GRID_TOP=$(jq -r '[.panels[] | select(.id == 3)][0].gridPos | "y=\(.y),x=\(.x)"' "$COST_USAGE_FILE")
assert_eq "p3 is positioned top-left (y=0,x=0)" "y=0,x=0" "$P3_GRID_TOP"

# ── Prom panels: key_hash filter (3 of 5; p2 Active Connections and p12 Shared Dict are global) ──

PROM_KEYHASH_PANELS=$(jq '[.panels[] | select(.datasource.uid == "prometheus") | select([.targets[].expr? | select(. != null) | select(test("key_hash"))] | length > 0)] | length' "$OPS_HEALTH_FILE")
assert_eq "Prometheus panels with key_hash filter" "3" "$PROM_KEYHASH_PANELS"

# ── p13 Stream Abort Rate: 2 targets (client + provider) ─────────────

P13_TITLE=$(jq -r '[.panels[] | select(.id == 13)][0].title' "$OPS_HEALTH_FILE")
assert_eq "p13 title is Stream Abort Rate" "Stream Abort Rate by Direction (%)" "$P13_TITLE"

P13_TARGET_COUNT=$(jq '[.panels[] | select(.id == 13)][0].targets | length' "$OPS_HEALTH_FILE")
assert_eq "p13 Abort Rate has 2 targets" "2" "$P13_TARGET_COUNT"

P13_HAS_IS_STREAM=$(jq '[[.panels[] | select(.id == 13)][0].targets[].rawSql | select(. != null) | select(test("is_stream = 1"))] | length > 0' "$OPS_HEALTH_FILE")
assert_eq "p13 filters is_stream = 1" "true" "$P13_HAS_IS_STREAM"

P13_HAS_ABORTED=$(jq '[[.panels[] | select(.id == 13)][0].targets[].rawSql | select(. != null) | select(test("aborted"))] | length > 0' "$OPS_HEALTH_FILE")
assert_eq "p13 references aborted column" "true" "$P13_HAS_ABORTED"

# ── p14 Stream Status: 3 stacked targets ──────────────────────────────

P14_TITLE=$(jq -r '[.panels[] | select(.id == 14)][0].title' "$OPS_HEALTH_FILE")
assert_eq "p14 title is Stream Status" "Stream Status (completed / client-aborted / provider-aborted)" "$P14_TITLE"

P14_TARGET_COUNT=$(jq '[.panels[] | select(.id == 14)][0].targets | length' "$OPS_HEALTH_FILE")
assert_eq "p14 Stream Status has 3 targets" "3" "$P14_TARGET_COUNT"

P14_LABELS=$(jq -r '[[.panels[] | select(.id == 14)][0].targets[].rawSql | select(. != null) | split("\u0027") | .[1]] | sort | join(",")' "$OPS_HEALTH_FILE")
assert_eq "p14 labels are Client,Completed,Provider" "Client aborted,Completed,Provider aborted" "$P14_LABELS"

# ── Brand palette enforcement across all 3 dashboards ─────────────────
# Allowed brand hex colors (lowercase). Every fixedColor override must use one of these.

BRAND_PAL_VIOLATIONS=""
for df in "$COST_USAGE_FILE" "$OPS_HEALTH_FILE" "$LEADERBOARD_FILE"; do
    v=$(jq -r '
      def brand: ["#50514f","#f25f5c","#ffe066","#247ba0","#70c1b3","#a5d0a8","#8cada7","#110b11","#b7990d","#f2f4cb","#ffffff","#c9a44c","#a8a9ad","#b07a3c"];
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
      if ($violations | length) == 0 then "" else ($violations | join(" | ")) end
    ' "$df")
    [ -n "$v" ] && BRAND_PAL_VIOLATIONS="$BRAND_PAL_VIOLATIONS $v"
done
if [ -z "$(echo "$BRAND_PAL_VIOLATIONS" | tr -d ' ')" ]; then
    echo "[PASS] All hex colors are brand palette (all 3 dashboards)"
    pass=$((pass + 1))
else
    echo "[FAIL] Brand palette violations:$BRAND_PAL_VIOLATIONS"
    fail=$((fail + 1))
fi

# ── p3 palette (in cost-usage) ────────────────────────────────────────

P3_PALETTE=$(jq -r '
  [ .panels[] | select(.id == 3) ][0] as $p3 |
  {} as $expected |
  reduce $p3.fieldConfig.overrides[] as $o (
    {};
    reduce $o.properties[] as $prop (
      .;
      if $prop.id == "displayName" then . + {__name: $prop.value}
      elif $prop.id == "color" and (.__name // null) != null then
        . + {(.__name): ($prop.value.fixedColor | ascii_downcase)} | del(.__name)
      else . end
    )
  ) | del(.__name) | . as $got |
  {
    "Total":                  "#70c1b3",
    "Input (uncached)":       "#247ba0",
    "Cached":                 "#8cada7",
    "Output (non-reasoning)": "#ffe066",
    "Reasoning":              "#f25f5c"
  } as $expected |
  if $got == $expected then "OK"
  else "MISMATCH expected=\($expected|tojson) got=\($got|tojson)" end
' "$COST_USAGE_FILE")
assert_eq "p3 uses brand palette (5 category tiles)" "OK" "$P3_PALETTE"

# ── p14 palette (in ops-health) ───────────────────────────────────────

P14_PALETTE=$(jq -r '
  [ .panels[] | select(.id == 14) ][0] as $p14 |
  reduce $p14.fieldConfig.overrides[] as $o (
    {};
    reduce $o.properties[] as $prop (
      .;
      if $prop.id == "color" then . + {($o.matcher.options): ($prop.value.fixedColor | ascii_downcase)} else . end
    )
  ) | . as $got |
  {
    "Completed":        "#70c1b3",
    "Client aborted":   "#f25f5c",
    "Provider aborted": "#ffe066"
  } as $expected |
  if $got == $expected then "OK"
  else "MISMATCH expected=\($expected|tojson) got=\($got|tojson)" end
' "$OPS_HEALTH_FILE")
assert_eq "p14 uses brand palette (completed/client/provider)" "OK" "$P14_PALETTE"

# ── p20 Leaderboard panel (in cost-leaderboard) ───────────────────────
# p20 is a stat panel (tiles), like p3 Token Usage by Category.
# Single ranked CTE returns all 10 rows; rowsToFields transformer maps each
# row to a tile. Medal colors (gold/silver/bronze) are baked into the SQL
# as a `Color` column and mapped to field config via the color handler.

P20_TITLE=$(jq -r '[.panels[] | select(.id == 20)][0].title' "$LEADERBOARD_FILE")
assert_eq "p20 title is Top Clients by Cost & Tokens" "Top Clients by Cost & Tokens" "$P20_TITLE"

P20_TYPE=$(jq -r '[.panels[] | select(.id == 20)][0].type' "$LEADERBOARD_FILE")
assert_eq "p20 is a stat panel (like p3)" "stat" "$P20_TYPE"

# p20: single target (ranked CTE returns all rows; rowsToFields expands)
P20_TGT=$(jq '[.panels[] | select(.id == 20)][0].targets | length' "$LEADERBOARD_FILE")
assert_eq "p20 has 1 target (ranked CTE)" "1" "$P20_TGT"

# p20: stat panel options match p3 Token Usage by Category
P20_CM=$(jq -r '[.panels[] | select(.id == 20)][0].options.colorMode' "$LEADERBOARD_FILE")
assert_eq "p20 colorMode is background_solid" "background_solid" "$P20_CM"
P20_TM=$(jq -r '[.panels[] | select(.id == 20)][0].options.textMode' "$LEADERBOARD_FILE")
assert_eq "p20 textMode is value_and_name (like p3)" "value_and_name" "$P20_TM"
P20_OR=$(jq -r '[.panels[] | select(.id == 20)][0].options.orientation' "$LEADERBOARD_FILE")
assert_eq "p20 orientation is horizontal (like p3)" "horizontal" "$P20_OR"
P20_GM=$(jq -r '[.panels[] | select(.id == 20)][0].options.graphMode' "$LEADERBOARD_FILE")
assert_eq "p20 graphMode is none (like p3)" "none" "$P20_GM"

# p20: default color white (#FFFFFF) for non-medal tiles
P20_DEF=$(jq -r '[.panels[] | select(.id == 20)][0].fieldConfig.defaults.color.fixedColor' "$LEADERBOARD_FILE" | tr '[:lower:]' '[:upper:]')
assert_eq "p20 default background is white" "#FFFFFF" "$P20_DEF"

# p20: no field overrides -- all color comes from SQL Color column
P20_OVR=$(jq -r '[.panels[] | select(.id == 20)][0].fieldConfig.overrides | length' "$LEADERBOARD_FILE")
assert_eq "p20 has no field overrides (color from SQL)" "0" "$P20_OVR"

# p20: rowsToFields transformer with Color -> color handler mapping
P20_TRANS=$(jq -r '[.panels[] | select(.id == 20)][0].transformations[0].id' "$LEADERBOARD_FILE")
assert_eq "p20 uses rowsToFields transformer" "rowsToFields" "$P20_TRANS"
P20_COLOR_MAP=$(jq -r '[.panels[] | select(.id == 20)][0].transformations[0].options.mappings[] | select(.fieldName=="Color") | .handlerKey' "$LEADERBOARD_FILE")
assert_eq "p20 maps Color column to color handler" "color" "$P20_COLOR_MAP"

P20_SQL=$(jq -r '[.panels[] | select(.id == 20)][0].targets[0].rawSql' "$LEADERBOARD_FILE")
echo "$P20_SQL" | grep -q 'GROUP BY client' && { echo "[PASS] p20 CTE groups by client"; pass=$((pass+1)); } || { echo "[FAIL] p20 missing GROUP BY client"; fail=$((fail+1)); }
echo "$P20_SQL" | grep -q 'ORDER BY total_cost DESC' && { echo "[PASS] p20 CTE orders by total_cost DESC"; pass=$((pass+1)); } || { echo "[FAIL] p20 missing ORDER BY total_cost DESC"; fail=$((fail+1)); }
echo "$P20_SQL" | grep -q "row_number() OVER () = 1, '#C9A44C'" && { echo "[PASS] p20 SQL bakes in matte gold for rank 1"; pass=$((pass+1)); } || { echo "[FAIL] p20 missing gold color in SQL"; fail=$((fail+1)); }
echo "$P20_SQL" | grep -q "row_number() OVER () = 2, '#A8A9AD'" && { echo "[PASS] p20 SQL bakes in matte silver for rank 2"; pass=$((pass+1)); } || { echo "[FAIL] p20 missing silver color in SQL"; fail=$((fail+1)); }
echo "$P20_SQL" | grep -q "row_number() OVER () = 3, '#B07A3C'" && { echo "[PASS] p20 SQL bakes in matte bronze for rank 3"; pass=$((pass+1)); } || { echo "[FAIL] p20 missing bronze color in SQL"; fail=$((fail+1)); }
echo "$P20_SQL" | grep -q 'multiIf' && { echo "[PASS] p20 uses multiIf for Mil/K formatting (like p3)"; pass=$((pass+1)); } || { echo "[FAIL] p20 missing multiIf formatting"; fail=$((fail+1)); }

# ── p21 Leaderboard panel (in cost-leaderboard) ───────────────────────

P21_TITLE=$(jq -r '[.panels[] | select(.id == 21)][0].title' "$LEADERBOARD_FILE")
assert_eq "p21 title is Top Models by Cost & Tokens" "Top Models by Cost & Tokens" "$P21_TITLE"

P21_TYPE=$(jq -r '[.panels[] | select(.id == 21)][0].type' "$LEADERBOARD_FILE")
assert_eq "p21 is a stat panel (like p20)" "stat" "$P21_TYPE"

P21_TGT=$(jq '[.panels[] | select(.id == 21)][0].targets | length' "$LEADERBOARD_FILE")
assert_eq "p21 has 1 target (ranked CTE)" "1" "$P21_TGT"

P21_CM=$(jq -r '[.panels[] | select(.id == 21)][0].options.colorMode' "$LEADERBOARD_FILE")
assert_eq "p21 colorMode is background_solid" "background_solid" "$P21_CM"
P21_TM=$(jq -r '[.panels[] | select(.id == 21)][0].options.textMode' "$LEADERBOARD_FILE")
assert_eq "p21 textMode is value_and_name (like p20)" "value_and_name" "$P21_TM"
P21_OR=$(jq -r '[.panels[] | select(.id == 21)][0].options.orientation' "$LEADERBOARD_FILE")
assert_eq "p21 orientation is horizontal (like p20)" "horizontal" "$P21_OR"
P21_GM=$(jq -r '[.panels[] | select(.id == 21)][0].options.graphMode' "$LEADERBOARD_FILE")
assert_eq "p21 graphMode is none (like p20)" "none" "$P21_GM"

P21_DEF=$(jq -r '[.panels[] | select(.id == 21)][0].fieldConfig.defaults.color.fixedColor' "$LEADERBOARD_FILE" | tr '[:lower:]' '[:upper:]')
assert_eq "p21 default background is white" "#FFFFFF" "$P21_DEF"

P21_OVR=$(jq -r '[.panels[] | select(.id == 21)][0].fieldConfig.overrides | length' "$LEADERBOARD_FILE")
assert_eq "p21 has no field overrides (color from SQL)" "0" "$P21_OVR"

P21_TRANS=$(jq -r '[.panels[] | select(.id == 21)][0].transformations[0].id' "$LEADERBOARD_FILE")
assert_eq "p21 uses rowsToFields transformer" "rowsToFields" "$P21_TRANS"
P21_COLOR_MAP=$(jq -r '[.panels[] | select(.id == 21)][0].transformations[0].options.mappings[] | select(.fieldName=="Color") | .handlerKey' "$LEADERBOARD_FILE")
assert_eq "p21 maps Color column to color handler" "color" "$P21_COLOR_MAP"

P21_SQL=$(jq -r '[.panels[] | select(.id == 21)][0].targets[0].rawSql' "$LEADERBOARD_FILE")
echo "$P21_SQL" | grep -q 'GROUP BY model_name' && { echo "[PASS] p21 CTE groups by model_name"; pass=$((pass+1)); } || { echo "[FAIL] p21 missing GROUP BY model_name"; fail=$((fail+1)); }
echo "$P21_SQL" | grep -q 'ORDER BY total_cost DESC' && { echo "[PASS] p21 CTE orders by total_cost DESC"; pass=$((pass+1)); } || { echo "[FAIL] p21 missing ORDER BY total_cost DESC"; fail=$((fail+1)); }
echo "$P21_SQL" | grep -q "row_number() OVER () = 1, '#C9A44C'" && { echo "[PASS] p21 SQL bakes in matte gold for rank 1"; pass=$((pass+1)); } || { echo "[FAIL] p21 missing gold color in SQL"; fail=$((fail+1)); }
echo "$P21_SQL" | grep -q "row_number() OVER () = 2, '#A8A9AD'" && { echo "[PASS] p21 SQL bakes in matte silver for rank 2"; pass=$((pass+1)); } || { echo "[FAIL] p21 missing silver color in SQL"; fail=$((fail+1)); }
echo "$P21_SQL" | grep -q "row_number() OVER () = 3, '#B07A3C'" && { echo "[PASS] p21 SQL bakes in matte bronze for rank 3"; pass=$((pass+1)); } || { echo "[FAIL] p21 missing bronze color in SQL"; fail=$((fail+1)); }
echo "$P21_SQL" | grep -q 'multiIf' && { echo "[PASS] p21 uses multiIf for Mil/K formatting (like p20)"; pass=$((pass+1)); } || { echo "[FAIL] p21 missing multiIf formatting"; fail=$((fail+1)); }

summary
