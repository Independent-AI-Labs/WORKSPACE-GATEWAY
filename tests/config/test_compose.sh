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
        echo "[FAIL] $desc -- expected: $expected, actual: $actual"
        fail=$((fail + 1))
    fi
}

summary() {
    echo ""
    echo "test_compose.sh: $pass passed, $fail failed"
    if [ "$fail" -gt 0 ]; then
        exit 1
    fi
}

COMPOSE_YAML="$REPO_ROOT/res/docker/docker-compose.yml"

JSON_DATA=$(yaml_to_json "$COMPOSE_YAML")
ret=$?
if [ "$ret" -ne 0 ]; then
    echo "[FAIL] Valid YAML"
    fail=$((fail + 1))
    summary
fi

assert_eq "Valid YAML" "ok" "ok"

HAS_APISIX=$(echo "$JSON_DATA" | jq '.services | has("apisix")')
assert_eq "Has apisix service" "true" "$HAS_APISIX"

HAS_CLICKHOUSE=$(echo "$JSON_DATA" | jq '.services | has("clickhouse")')
assert_eq "Has clickhouse service" "true" "$HAS_CLICKHOUSE"

HAS_VECTOR=$(echo "$JSON_DATA" | jq '.services | has("vector")')
assert_eq "Has vector service" "true" "$HAS_VECTOR"

HAS_OPENBAO=$(echo "$JSON_DATA" | jq '.services | has("openbao")')
assert_eq "Has openbao service" "true" "$HAS_OPENBAO"

HAS_PROMETHEUS=$(echo "$JSON_DATA" | jq '.services | has("prometheus")')
assert_eq "Has prometheus service" "true" "$HAS_PROMETHEUS"

HAS_GRAFANA=$(echo "$JSON_DATA" | jq '.services | has("grafana")')
assert_eq "Has grafana service" "true" "$HAS_GRAFANA"

HAS_ETCD=$(echo "$JSON_DATA" | jq '.services | has("etcd")')
assert_eq "Has etcd service" "true" "$HAS_ETCD"

OPENBAO_BUILD=$(echo "$JSON_DATA" | jq '.services.openbao.build != null')
assert_eq "OpenBao uses custom build (Dockerfile.openbao)" "true" "$OPENBAO_BUILD"

OPENBAO_VOLUME=$(echo "$JSON_DATA" | jq '[.volumes | has("openbao-data")] | any')
assert_eq "OpenBao has persistent volume" "true" "$OPENBAO_VOLUME"

PROMETHEUS_IMAGE=$(echo "$JSON_DATA" | jq -r '.services.prometheus.image')
PROMETHEUS_TAG=$(echo "$PROMETHEUS_IMAGE" | sed 's|.*:||' | sed 's/^v//')
PROMETHEUS_REPO=$(echo "$PROMETHEUS_IMAGE" | sed 's|:.*||')
assert_eq "Prometheus image repo is prom/prometheus" "prom/prometheus" "$PROMETHEUS_REPO"
if version_ge "$PROMETHEUS_TAG" "3.13.0"; then
    echo "[PASS] Prometheus image tag >= 3.13.0 (got $PROMETHEUS_TAG)"
    pass=$((pass + 1))
else
    echo "[FAIL] Prometheus image tag >= 3.13.0 (got $PROMETHEUS_TAG)"
    fail=$((fail + 1))
fi

GRAFANA_IMAGE=$(echo "$JSON_DATA" | jq -r '.services.grafana.image')
GRAFANA_TAG=$(echo "$GRAFANA_IMAGE" | sed 's|.*:||')
GRAFANA_REPO=$(echo "$GRAFANA_IMAGE" | sed 's|:.*||')
assert_eq "Grafana image repo is grafana/grafana-oss" "grafana/grafana-oss" "$GRAFANA_REPO"
if version_ge "$GRAFANA_TAG" "13.0.2"; then
    echo "[PASS] Grafana image tag >= 13.0.2 (got $GRAFANA_TAG)"
    pass=$((pass + 1))
else
    echo "[FAIL] Grafana image tag >= 13.0.2 (got $GRAFANA_TAG)"
    fail=$((fail + 1))
fi

OPENBAO_PORT=$(echo "$JSON_DATA" | jq '[.services.openbao.ports[] | select(. == "8201:8200")] | length')
assert_eq "OpenBao exposes port 8201:8200" "1" "$OPENBAO_PORT"

OPENBAO_NETWORK=$(echo "$JSON_DATA" | jq '[.services.openbao.networks[] | select(. == "gateway")] | length')
assert_eq "OpenBao on gateway network" "1" "$OPENBAO_NETWORK"

PROMETHEUS_CONTAINER=$(echo "$JSON_DATA" | jq -r '.services.prometheus.container_name')
assert_eq "Prometheus container name is gw-prometheus" "gw-prometheus" "$PROMETHEUS_CONTAINER"

PROMETHEUS_PORT=$(echo "$JSON_DATA" | jq '[.services.prometheus.ports[] | select(. == "9092:9090")] | length')
assert_eq "Prometheus exposes port 9092:9090" "1" "$PROMETHEUS_PORT"

PROMETHEUS_NETWORK=$(echo "$JSON_DATA" | jq '[.services.prometheus.networks[] | select(. == "gateway")] | length')
assert_eq "Prometheus on gateway network" "1" "$PROMETHEUS_NETWORK"

GRAFANA_CONTAINER=$(echo "$JSON_DATA" | jq -r '.services.grafana.container_name')
assert_eq "Grafana container name is gw-grafana" "gw-grafana" "$GRAFANA_CONTAINER"

GRAFANA_PORT=$(echo "$JSON_DATA" | jq '[.services.grafana.ports[] | select(. == "127.0.0.1:3030:3000")] | length')
assert_eq "Grafana binds localhost only on 3030:3000" "1" "$GRAFANA_PORT"

GRAFANA_NETWORK=$(echo "$JSON_DATA" | jq '[.services.grafana.networks[] | select(. == "gateway")] | length')
assert_eq "Grafana on gateway network" "1" "$GRAFANA_NETWORK"

GRAFANA_PLUGIN=$(echo "$JSON_DATA" | jq -r '.services.grafana.environment.GF_PLUGINS_PREINSTALL')
assert_eq "Grafana preinstalls ClickHouse plugin" "grafana-clickhouse-datasource" "$GRAFANA_PLUGIN"

GRAFANA_ANON=$(echo "$JSON_DATA" | jq -r '.services.grafana.environment.GF_AUTH_ANONYMOUS_ENABLED')
assert_eq "Grafana anonymous auth defaults off" '${GF_AUTH_ANONYMOUS_ENABLED:-false}' "$GRAFANA_ANON"

GRAFANA_PROXY=$(echo "$JSON_DATA" | jq -r '.services.grafana.environment.GF_AUTH_PROXY_ENABLED')
assert_eq "Grafana auth-proxy defaults on" '${GF_AUTH_PROXY_ENABLED:-true}' "$GRAFANA_PROXY"

GRAFANA_SUBPATH=$(echo "$JSON_DATA" | jq -r '.services.grafana.environment.GF_SERVER_SERVE_FROM_SUB_PATH')
assert_eq "Grafana serves from subpath" "true" "$GRAFANA_SUBPATH"

APISIX_PORT_9080=$(echo "$JSON_DATA" | jq '[.services.apisix.ports[] | select(. == "9080:9080")] | length')
assert_eq "APISIX exposes port 9080" "1" "$APISIX_PORT_9080"

APISIX_PORT_9100=$(echo "$JSON_DATA" | jq '[.services.apisix.ports[] | select(. == "9100:9100")] | length')
assert_eq "APISIX exposes port 9100 for prometheus" "1" "$APISIX_PORT_9100"

APISIX_PORT_9180=$(echo "$JSON_DATA" | jq '[.services.apisix.ports[] | select(. == "9180:9180")] | length')
assert_eq "APISIX exposes port 9180 for Admin API + Dashboard" "1" "$APISIX_PORT_9180"

APISIX_MOUNTS=$(echo "$JSON_DATA" | jq -r '.services.apisix.volumes[]')
HAS_APISIX_YAML=$(echo "$APISIX_MOUNTS" | grep -c "apisix.yaml" || true)
assert_eq "APISIX mounts apisix.yaml" "1" "$HAS_APISIX_YAML"

HAS_REDACT_PATTERNS=$(echo "$APISIX_MOUNTS" | grep -c "redact-patterns.json" || true)
assert_eq "APISIX mounts redact-patterns.json" "1" "$HAS_REDACT_PATTERNS"

HAS_COST_CALC_MOUNT=$(echo "$APISIX_MOUNTS" | grep -c "cost_calc.lua" || true)
assert_eq "APISIX mounts cost_calc.lua" "1" "$HAS_COST_CALC_MOUNT"

HAS_KEY_META_MOUNT=$(echo "$APISIX_MOUNTS" | grep -c "key-meta.lua" || true)
assert_eq "APISIX mounts key-meta.lua" "1" "$HAS_KEY_META_MOUNT"

HAS_SSE_USAGE_MOUNT=$(echo "$APISIX_MOUNTS" | grep -c "sse-usage.lua" || true)
assert_eq "APISIX mounts sse-usage.lua" "1" "$HAS_SSE_USAGE_MOUNT"

APISIX_VOLUME_COUNT=$(echo "$APISIX_MOUNTS" | wc -l | tr -d ' ')
assert_eq "APISIX has 10 volume mounts (3 config + 7 plugins)" "10" "$APISIX_VOLUME_COUNT"

CLICKHOUSE_MOUNTS=$(echo "$JSON_DATA" | jq -r '.services.clickhouse.volumes[]')
HAS_INIT_SQL=$(echo "$CLICKHOUSE_MOUNTS" | grep -c "clickhouse-init.sql" || true)
assert_eq "ClickHouse mounts clickhouse-init.sql" "1" "$HAS_INIT_SQL"

VECTOR_MOUNTS=$(echo "$JSON_DATA" | jq -r '.services.vector.volumes[]')
HAS_VECTOR_TOML=$(echo "$VECTOR_MOUNTS" | grep -c "vector.toml" || true)
assert_eq "Vector mounts vector.toml" "1" "$HAS_VECTOR_TOML"

VECTOR_PORT_8080=$(echo "$JSON_DATA" | jq '[.services.vector.ports[] | select(. == "8080:8080")] | length')
assert_eq "Vector exposes port 8080" "1" "$VECTOR_PORT_8080"

VECTOR_CMD=$(echo "$JSON_DATA" | jq -r '[.services.vector.command[] | select(. == "/etc/vector/vector.toml")] | length')
assert_eq "Vector command specifies vector.toml config" "1" "$VECTOR_CMD"

ETCD_CONTAINER=$(echo "$JSON_DATA" | jq -r '.services.etcd.container_name')
assert_eq "etcd container name is gw-etcd" "gw-etcd" "$ETCD_CONTAINER"

ETCD_PORT=$(echo "$JSON_DATA" | jq '[.services.etcd.ports[] | select(. == "2379:2379")] | length')
assert_eq "etcd exposes port 2379" "1" "$ETCD_PORT"

ETCD_NETWORK=$(echo "$JSON_DATA" | jq '[.services.etcd.networks[] | select(. == "gateway")] | length')
assert_eq "etcd on gateway network" "1" "$ETCD_NETWORK"

HAS_GATEWAY=$(echo "$JSON_DATA" | jq '.networks | has("gateway")')
assert_eq "Networks has gateway" "true" "$HAS_GATEWAY"

HAS_DATAOPS=$(echo "$JSON_DATA" | jq '.networks | has("dataops")')
assert_eq "Networks has dataops" "true" "$HAS_DATAOPS"

HAS_PROM_VOLUME=$(echo "$JSON_DATA" | jq '.volumes | has("prometheus-data")')
assert_eq "Has prometheus-data volume" "true" "$HAS_PROM_VOLUME"

HAS_GRAFANA_VOLUME=$(echo "$JSON_DATA" | jq '.volumes | has("grafana-data")')
assert_eq "Has grafana-data volume" "true" "$HAS_GRAFANA_VOLUME"

HAS_ETCD_VOLUME=$(echo "$JSON_DATA" | jq '.volumes | has("etcd-data")')
assert_eq "Has etcd-data volume" "true" "$HAS_ETCD_VOLUME"

APISIX_ENV_FILE=$(echo "$JSON_DATA" | jq -r '.services.apisix.env_file[]')
HAS_ENV_FILE=$(echo "$APISIX_ENV_FILE" | grep -c "\.env" || true)
assert_eq "APISIX has env_file pointing to .env" "1" "$HAS_ENV_FILE"

APISIX_DEPS=$(echo "$JSON_DATA" | jq -r '.services.apisix.depends_on[]')
HAS_OPENBAO_DEP=$(echo "$APISIX_DEPS" | grep -c "openbao" || true)
assert_eq "APISIX depends on openbao" "1" "$HAS_OPENBAO_DEP"

HAS_ETCD_DEP=$(echo "$APISIX_DEPS" | grep -c "etcd" || true)
assert_eq "APISIX depends on etcd" "1" "$HAS_ETCD_DEP"

summary