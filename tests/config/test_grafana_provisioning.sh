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

# ── dashboard JSON ────────────────────────────────────────────────────

DASHBOARD_FILE="$REPO_ROOT/conf/grafana/dashboards/gateway-overview.json"

if [ ! -f "$DASHBOARD_FILE" ]; then
    echo "[FAIL] Dashboard JSON missing: $DASHBOARD_FILE"
    fail=$((fail + 1))
    summary
fi

assert_eq "Dashboard JSON exists" "ok" "ok"

if ! jq empty "$DASHBOARD_FILE" 2>/dev/null; then
    echo "[FAIL] Dashboard JSON is valid JSON"
    fail=$((fail + 1))
    summary
fi

assert_eq "Dashboard JSON is valid" "ok" "ok"

DASH_TITLE=$(jq -r '.title' "$DASHBOARD_FILE")
assert_eq "Dashboard title is Gateway Overview" "Gateway Overview" "$DASH_TITLE"

DASH_UID=$(jq -r '.uid' "$DASHBOARD_FILE")
assert_eq "Dashboard UID is gateway-overview" "gateway-overview" "$DASH_UID"

PANEL_COUNT=$(jq '.panels | length' "$DASHBOARD_FILE")
assert_eq "Dashboard has 14 panels" "14" "$PANEL_COUNT"

# Verify panels reference correct datasources
PROM_PANELS=$(jq '[.panels[] | select(.datasource.uid == "prometheus")] | length' "$DASHBOARD_FILE")
assert_eq "Panels using Prometheus datasource" "8" "$PROM_PANELS"

CH_PANELS=$(jq '[.panels[] | select(.datasource.uid == "clickhouse")] | length' "$DASHBOARD_FILE")
assert_eq "Panels using ClickHouse datasource" "6" "$CH_PANELS"

# ── p3 Token Usage stat: 5 field overrides, 5 targets (one per category) ─────

P3_OVERRIDES=$(jq '[.panels[] | select(.id == 3)][0].fieldConfig.overrides | length' "$DASHBOARD_FILE")
assert_eq "p3 has 5 field overrides (Total, Input, Cached, Output, Reasoning)" "5" "$P3_OVERRIDES"

P3_TARGETS=$(jq '[.panels[] | select(.id == 3)][0].targets | length' "$DASHBOARD_FILE")
assert_eq "p3 has 5 targets (one per category)" "5" "$P3_TARGETS"

# ── p16 and p17 removed (Cost by Source panels) ──────────────────────

P16_EXISTS=$(jq '[.panels[] | select(.id == 16)] | length' "$DASHBOARD_FILE")
assert_eq "p16 panel removed" "0" "$P16_EXISTS"

P17_EXISTS=$(jq '[.panels[] | select(.id == 17)] | length' "$DASHBOARD_FILE")
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

API_KEY_ALLVALUE=$(jq -r '[.templating.list[] | select(.name == "api_key")] | if length == 0 then "None" else (.[0].allValue | if . == null then "None" else . end) end' "$DASHBOARD_FILE")
assert_eq "api_key variable has no allValue (Grafana expands)" "None" "$API_KEY_ALLVALUE"

NO_PROM_VAR=$(jq '[.templating.list[] | select(.name == "api_key_prom")] | length' "$DASHBOARD_FILE")
assert_eq "No api_key_prom variable (single var for CH+Prom)" "0" "$NO_PROM_VAR"

# ── No $__conditionalAll macros in any ClickHouse panel ───────────────

COND_ALL_COUNT=$(jq '[.panels[].targets[].rawSql | select(. != null) | select(test("\\$\\$__conditionalAll"))] | length' "$DASHBOARD_FILE")
assert_eq "No \$__conditionalAll macros in dashboard" "0" "$COND_ALL_COUNT"

# ── ClickHouse panels use \${api_key:singlequote} directly ────────────

CH_APIKEY_PANELS=$(jq '[.panels[] | select(.datasource.uid == "clickhouse") | select([.targets[].rawSql? | select(. != null) | select(test("\\$\\{api_key:singlequote\\}"))] | length > 0)] | length' "$DASHBOARD_FILE")
assert_eq "ClickHouse panels with \${api_key:singlequote}" "6" "$CH_APIKEY_PANELS"

# ── p3 Token Usage stat: 5 tiles, one per category ───────────────────

P3_TITLE=$(jq -r '[.panels[] | select(.id == 3)][0].title' "$DASHBOARD_FILE")
assert_eq "p3 title is Token Usage by Category" "Token Usage by Category" "$P3_TITLE"

P3_TYPE=$(jq -r '[.panels[] | select(.id == 3)][0].type' "$DASHBOARD_FILE")
assert_eq "p3 is a stat panel" "stat" "$P3_TYPE"

P3_TARGET_COUNT=$(jq '[.panels[] | select(.id == 3)][0].targets | length' "$DASHBOARD_FILE")
assert_eq "p3 Token Usage has 5 targets (one per category)" "5" "$P3_TARGET_COUNT"

P3_HAS_COST=$(jq '[[.panels[] | select(.id == 3)][0].targets[].rawSql | select(. != null) | select(test("cost"))] | length > 0' "$DASHBOARD_FILE")
assert_eq "p3 queries reference cost" "true" "$P3_HAS_COST"

P3_HAS_5_CATEGORIES=$(jq '[.panels[] | select(.id == 3)][0].targets | length' "$DASHBOARD_FILE")
assert_eq "p3 has 5 categories (Total + Input + Cached + Output + Reasoning)" "5" "$P3_HAS_5_CATEGORIES"

P3_OVERRIDES=$(jq '[.panels[] | select(.id == 3)][0].fieldConfig.overrides | length' "$DASHBOARD_FILE")
assert_eq "p3 has 5 field overrides (Total, Input, Cached, Output, Reasoning)" "5" "$P3_OVERRIDES"

# ── p15 Cost Over Time by Model ──────────────────────────────────────

P15_TITLE=$(jq -r '[.panels[] | select(.id == 15)][0].title' "$DASHBOARD_FILE")
assert_eq "p15 title is Cost Over Time" "Cost Over Time by Model ($)" "$P15_TITLE"

P15_TYPE=$(jq -r '[.panels[] | select(.id == 15)][0].type' "$DASHBOARD_FILE")
assert_eq "p15 is a timeseries" "timeseries" "$P15_TYPE"

P15_HAS_COST=$(jq '[[.panels[] | select(.id == 15)][0].targets[].rawSql | select(. != null) | select(test("sum\\(cost\\)"))] | length > 0' "$DASHBOARD_FILE")
assert_eq "p15 query sums cost" "true" "$P15_HAS_COST"

P15_HAS_APIKEY=$(jq '[[.panels[] | select(.id == 15)][0].targets[].rawSql | select(. != null) | select(test("\\$\\{api_key:singlequote\\}"))] | length > 0' "$DASHBOARD_FILE")
assert_eq "p15 filters by \${api_key:singlequote}" "true" "$P15_HAS_APIKEY"

# ── p3 should be top-left (y=0, x=0) per value-interest order ─────────

P3_GRID_TOP=$(jq -r '[.panels[] | select(.id == 3)][0].gridPos | "y=\(.y),x=\(.x)"' "$DASHBOARD_FILE")
assert_eq "p3 is positioned top-left (y=0,x=0)" "y=0,x=0" "$P3_GRID_TOP"

# ── Prom panels: key_hash filter (6 of 8; p2/p12 are global) ──────────

PROM_KEYHASH_PANELS=$(jq '[.panels[] | select(.datasource.uid == "prometheus") | select([.targets[].expr? | select(. != null) | select(test("key_hash"))] | length > 0)] | length' "$DASHBOARD_FILE")
assert_eq "Prometheus panels with key_hash filter" "6" "$PROM_KEYHASH_PANELS"

# ── p13 Stream Abort Rate: 2 targets (client + provider) ─────────────

P13_TITLE=$(jq -r '[.panels[] | select(.id == 13)][0].title' "$DASHBOARD_FILE")
assert_eq "p13 title is Stream Abort Rate" "Stream Abort Rate by Direction (%)" "$P13_TITLE"

P13_TARGET_COUNT=$(jq '[.panels[] | select(.id == 13)][0].targets | length' "$DASHBOARD_FILE")
assert_eq "p13 Abort Rate has 2 targets" "2" "$P13_TARGET_COUNT"

P13_HAS_IS_STREAM=$(jq '[[.panels[] | select(.id == 13)][0].targets[].rawSql | select(. != null) | select(test("is_stream = 1"))] | length > 0' "$DASHBOARD_FILE")
assert_eq "p13 filters is_stream = 1" "true" "$P13_HAS_IS_STREAM"

P13_HAS_ABORTED=$(jq '[[.panels[] | select(.id == 13)][0].targets[].rawSql | select(. != null) | select(test("aborted"))] | length > 0' "$DASHBOARD_FILE")
assert_eq "p13 references aborted column" "true" "$P13_HAS_ABORTED"

# ── p14 Stream Status: 3 stacked targets ──────────────────────────────

P14_TITLE=$(jq -r '[.panels[] | select(.id == 14)][0].title' "$DASHBOARD_FILE")
assert_eq "p14 title is Stream Status" "Stream Status (completed / client-aborted / provider-aborted)" "$P14_TITLE"

P14_TARGET_COUNT=$(jq '[.panels[] | select(.id == 14)][0].targets | length' "$DASHBOARD_FILE")
assert_eq "p14 Stream Status has 3 targets" "3" "$P14_TARGET_COUNT"

P14_LABELS=$(jq -r '[[.panels[] | select(.id == 14)][0].targets[].rawSql | select(. != null) | split("\u0027") | .[1]] | sort | join(",")' "$DASHBOARD_FILE")
assert_eq "p14 labels are Client,Completed,Provider" "Client aborted,Completed,Provider aborted" "$P14_LABELS"

# ── Brand palette enforcement ─────────────────────────────────────────
# Allowed brand hex colors (lowercase). Every fixedColor override must use one of these.

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
assert_eq "All hex colors are brand palette" "OK" "$BRAND_HEX"

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
' "$DASHBOARD_FILE")
assert_eq "p3 uses brand palette (5 category tiles)" "OK" "$P3_PALETTE"

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
' "$DASHBOARD_FILE")
assert_eq "p14 uses brand palette (completed/client/provider)" "OK" "$P14_PALETTE"

summary
