#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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

DS_JSON=$(python3 -c "
import yaml, json
with open('$DS_FILE') as f:
    data = yaml.safe_load(f)
print(json.dumps(data))
")

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

DASH_JSON=$(python3 -c "
import yaml, json
with open('$DASH_PROVIDER_FILE') as f:
    data = yaml.safe_load(f)
print(json.dumps(data))
")

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

if ! python3 -c "import json; json.load(open('$DASHBOARD_FILE'))" 2>/dev/null; then
    echo "[FAIL] Dashboard JSON is valid JSON"
    fail=$((fail + 1))
    summary
fi

assert_eq "Dashboard JSON is valid" "ok" "ok"

DASH_TITLE=$(python3 -c "import json; d=json.load(open('$DASHBOARD_FILE')); print(d['title'])")
assert_eq "Dashboard title is Gateway Overview" "Gateway Overview" "$DASH_TITLE"

DASH_UID=$(python3 -c "import json; d=json.load(open('$DASHBOARD_FILE')); print(d['uid'])")
assert_eq "Dashboard UID is gateway-overview" "gateway-overview" "$DASH_UID"

PANEL_COUNT=$(python3 -c "import json; d=json.load(open('$DASHBOARD_FILE')); print(len(d['panels']))")
assert_eq "Dashboard has 12 panels" "12" "$PANEL_COUNT"

# Verify panels reference correct datasources
PROM_PANELS=$(python3 -c "
import json
d = json.load(open('$DASHBOARD_FILE'))
count = sum(1 for p in d['panels'] if p.get('datasource', {}).get('uid') == 'prometheus')
print(count)
")
assert_eq "Panels using Prometheus datasource" "8" "$PROM_PANELS"

CH_PANELS=$(python3 -c "
import json
d = json.load(open('$DASHBOARD_FILE'))
count = sum(1 for p in d['panels'] if p.get('datasource', {}).get('uid') == 'clickhouse')
print(count)
")
assert_eq "Panels using ClickHouse datasource" "4" "$CH_PANELS"

# ── prometheus config ─────────────────────────────────────────────────

PROM_FILE="$REPO_ROOT/conf/prometheus.yml"

if [ ! -f "$PROM_FILE" ]; then
    echo "[FAIL] Prometheus config missing: $PROM_FILE"
    fail=$((fail + 1))
    summary
fi

assert_eq "Prometheus config exists" "ok" "ok"

PROM_JSON=$(python3 -c "
import yaml, json
with open('$PROM_FILE') as f:
    data = yaml.safe_load(f)
print(json.dumps(data))
")

SCRAPE_COUNT=$(echo "$PROM_JSON" | jq '.scrape_configs | length')
assert_eq "Two scrape configs" "2" "$SCRAPE_COUNT"

HAS_APISIX_JOB=$(echo "$PROM_JSON" | jq '[.scrape_configs[] | select(.job_name == "gateway-apisix")] | length')
assert_eq "Has gateway-apisix scrape job" "1" "$HAS_APISIX_JOB"

APISIX_TARGET=$(echo "$PROM_JSON" | jq -r '.scrape_configs[] | select(.job_name == "gateway-apisix") | .static_configs[0].targets[0]')
assert_eq "APISIX scrape target is apisix:9100" "apisix:9100" "$APISIX_TARGET"

APISIX_METRICS_PATH=$(echo "$PROM_JSON" | jq -r '.scrape_configs[] | select(.job_name == "gateway-apisix") | .metrics_path')
assert_eq "APISIX metrics path correct" "/apisix/prometheus/metrics" "$APISIX_METRICS_PATH"

summary
