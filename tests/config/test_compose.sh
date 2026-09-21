#!/bin/bash
set -euo pipefail

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
    _SELF="$SHG_SCRIPT_PATH"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/yaml_helpers.sh" || exit 1

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

TEST_JSON=$(yaml_to_json "$REPO_ROOT/tests/docker-compose.test.yml")
PROD_SERVICES=$(echo "$JSON_DATA" | jq -c '.services | keys | sort')
TEST_SERVICES=$(echo "$TEST_JSON" | jq -c '.services | keys | sort')
assert_eq "Test Compose service parity" "$PROD_SERVICES" "$TEST_SERVICES"

PROD_APISIX_MOUNTS=$(echo "$JSON_DATA" | jq -c '[.services.apisix.volumes[] | split(":")[0]] | sort')
TEST_APISIX_MOUNTS=$(echo "$TEST_JSON" | jq -c '[.services.apisix.volumes[] | split(":")[0]] | sort')
assert_eq "Test Compose APISIX mount parity" "$PROD_APISIX_MOUNTS" "$TEST_APISIX_MOUNTS"

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
PROMETHEUS_REPO=$(echo "$PROMETHEUS_IMAGE" | sed 's#@sha256:.*##' | sed 's#:.*##')
assert_eq "Prometheus image repo is prom/prometheus" "prom/prometheus" "$PROMETHEUS_REPO"
if echo "$PROMETHEUS_IMAGE" | grep -q '@sha256:'; then
    echo "[PASS] Prometheus image is digest-pinned (immutable)"
    pass=$((pass + 1))
else
    PROMETHEUS_TAG=$(echo "$PROMETHEUS_IMAGE" | sed 's#.*:##' | sed 's/^v//')
    if version_ge "$PROMETHEUS_TAG" "3.13.0"; then
        echo "[PASS] Prometheus image tag >= 3.13.0 (got $PROMETHEUS_TAG)"
        pass=$((pass + 1))
    else
        echo "[FAIL] Prometheus image tag >= 3.13.0 (got $PROMETHEUS_TAG)"
        fail=$((fail + 1))
    fi
fi

GRAFANA_IMAGE=$(echo "$JSON_DATA" | jq -r '.services.grafana.image')
GRAFANA_TAG=$(echo "$GRAFANA_IMAGE" | sed 's#.*:##')
GRAFANA_REPO=$(echo "$GRAFANA_IMAGE" | sed 's#:.*##')
assert_eq "Grafana image repo is grafana/grafana-oss" "grafana/grafana-oss" "$GRAFANA_REPO"
if version_ge "$GRAFANA_TAG" "13.0.2"; then
    echo "[PASS] Grafana image tag >= 13.0.2 (got $GRAFANA_TAG)"
    pass=$((pass + 1))
else
    echo "[FAIL] Grafana image tag >= 13.0.2 (got $GRAFANA_TAG)"
    fail=$((fail + 1))
fi

OPENBAO_PORT=$(echo "$JSON_DATA" | jq '(.services.openbao.ports // []) | length')
assert_eq "OpenBao publishes no host ports (exec-only access)" "0" "$OPENBAO_PORT"

OPENBAO_NETWORK=$(echo "$JSON_DATA" | jq '[.services.openbao.networks | keys[] | select(. == "gw-secrets")] | length')
assert_eq "OpenBao isolated on gw-secrets network" "1" "$OPENBAO_NETWORK"

PROMETHEUS_CONTAINER=$(echo "$JSON_DATA" | jq -r '.services.prometheus.container_name')
assert_eq "Prometheus container name is gw-prometheus" "gw-prometheus" "$PROMETHEUS_CONTAINER"

PROMETHEUS_PORT=$(echo "$JSON_DATA" | jq '(.services.prometheus.ports // []) | length')
assert_eq "Prometheus publishes no host ports (exec-only access)" "0" "$PROMETHEUS_PORT"

PROMETHEUS_NETWORK=$(echo "$JSON_DATA" | jq '[.services.prometheus.networks | keys[] | select(. == "gw-metrics")] | length')
assert_eq "Prometheus isolated on gw-metrics network" "1" "$PROMETHEUS_NETWORK"

GRAFANA_CONTAINER=$(echo "$JSON_DATA" | jq -r '.services.grafana.container_name')
assert_eq "Grafana container name is gw-grafana" "gw-grafana" "$GRAFANA_CONTAINER"

GRAFANA_PORT=$(echo "$JSON_DATA" | jq '[.services.grafana.ports[] | select(. == "127.0.0.1:3030:3000")] | length')
assert_eq "Grafana binds localhost only on 3030:3000" "1" "$GRAFANA_PORT"

GRAFANA_CH_NETWORK=$(echo "$JSON_DATA" | jq '[.services.grafana.networks | keys[] | select(. == "gw-ch")] | length')
assert_eq "Grafana on gw-ch network (ClickHouse datasource)" "1" "$GRAFANA_CH_NETWORK"

GRAFANA_METRICS_NETWORK=$(echo "$JSON_DATA" | jq '[.services.grafana.networks | keys[] | select(. == "gw-metrics")] | length')
assert_eq "Grafana on gw-metrics network (Prometheus datasource)" "1" "$GRAFANA_METRICS_NETWORK"

GRAFANA_EDGE_NETWORK=$(echo "$JSON_DATA" | jq '[.services.grafana.networks | keys[] | select(. == "gw-edge")] | length')
assert_eq "Grafana on gw-edge network (edge-proxy boundary)" "1" "$GRAFANA_EDGE_NETWORK"

GRAFANA_EDGE_IP=$(echo "$JSON_DATA" | jq -r '.services.grafana.networks["gw-edge"].ipv4_address')
assert_eq "Grafana pinned on gw-edge (edge proxy proxy_pass target)" "10.99.60.3" "$GRAFANA_EDGE_IP"

GRAFANA_PLUGIN=$(echo "$JSON_DATA" | jq -r '.services.grafana.environment.GF_PLUGINS_PREINSTALL')
assert_eq "Grafana preinstalls ClickHouse + Business Text plugins (bare IDs; env var has no version-pin syntax)" "grafana-clickhouse-datasource,marcusolsson-dynamictext-panel" "$GRAFANA_PLUGIN"

GRAFANA_ANON=$(echo "$JSON_DATA" | jq -r '.services.grafana.environment.GF_AUTH_ANONYMOUS_ENABLED // "absent"')
assert_eq "Grafana anonymous auth removed entirely" "absent" "$GRAFANA_ANON"

GRAFANA_PROXY=$(echo "$JSON_DATA" | jq -r '.services.grafana.environment.GF_AUTH_PROXY_ENABLED')
assert_eq "Grafana auth-proxy on" "true" "$GRAFANA_PROXY"

GRAFANA_PROXY_WHITELIST=$(echo "$JSON_DATA" | jq -r '.services.grafana.environment.GF_AUTH_PROXY_WHITELIST')
assert_eq "Grafana auth-proxy whitelist pinned to edge CIDR" '${GRAFANA_EDGE_CIDR:-10.99.60.2/32, 127.0.0.1/32}' "$GRAFANA_PROXY_WHITELIST"

GRAFANA_COOKIE=$(echo "$JSON_DATA" | jq -r '.services.grafana.environment.GF_SECURITY_COOKIE_SECURE')
assert_eq "Grafana cookies require secure transport" "true" "$GRAFANA_COOKIE"

GRAFANA_SUBPATH=$(echo "$JSON_DATA" | jq -r '.services.grafana.environment.GF_SERVER_SERVE_FROM_SUB_PATH')
assert_eq "Grafana serves from subpath" "true" "$GRAFANA_SUBPATH"

GRAFANA_ENV_FILE=$(echo "$JSON_DATA" | jq '[.services.grafana.env_file[] | select(endswith(".env"))] | length')
assert_eq "Grafana loads .env (CH_GRAFANA_RO_PASSWORD for datasource provisioning)" "1" "$GRAFANA_ENV_FILE"

APISIX_PORT_9080=$(echo "$JSON_DATA" | jq '[.services.apisix.ports[] | select(. == "9080:9080")] | length')
assert_eq "APISIX exposes port 9080" "1" "$APISIX_PORT_9080"

APISIX_PORT_9100=$(echo "$JSON_DATA" | jq '[.services.apisix.ports[] | select(contains("9100"))] | length')
assert_eq "APISIX metrics port 9100 unpublished" "0" "$APISIX_PORT_9100"

APISIX_PORT_9180=$(echo "$JSON_DATA" | jq '.services.apisix.ports | length')
assert_eq "APISIX publishes only data-plane ports (9080/9443)" "2" "$APISIX_PORT_9180"

APISIX_STATIC_IP=$(echo "$JSON_DATA" | jq -r '.services.apisix.networks["gw-ch"].ipv4_address')
assert_eq "APISIX has static gw-ch address for Admin API seeding" "10.99.10.2" "$APISIX_STATIC_IP"

APISIX_MOUNTS=$(echo "$JSON_DATA" | jq -r '.services.apisix.volumes[]')
HAS_APISIX_YAML_RC=0
HAS_APISIX_YAML=$(echo "$APISIX_MOUNTS" | grep -c "apisix.yaml" ) || { HAS_APISIX_YAML_RC=$?; HAS_APISIX_YAML="0"; }
assert_eq "APISIX mounts apisix.yaml" "1" "$HAS_APISIX_YAML"

HAS_CONFIG_YAML_RC=0
HAS_CONFIG_YAML=$(echo "$APISIX_MOUNTS" | grep -c "config.yaml" ) || { HAS_CONFIG_YAML_RC=$?; HAS_CONFIG_YAML="0"; }
assert_eq "APISIX mounts config.yaml" "1" "$HAS_CONFIG_YAML"

HAS_REDACT_PATTERNS_RC=0
HAS_REDACT_PATTERNS=$(echo "$APISIX_MOUNTS" | grep -c "redact-patterns.json" ) || { HAS_REDACT_PATTERNS_RC=$?; HAS_REDACT_PATTERNS="0"; }
assert_eq "APISIX mounts redact-patterns.json" "1" "$HAS_REDACT_PATTERNS"

HAS_PROVIDERS_MOUNT_RC=0
HAS_PROVIDERS_MOUNT=$(echo "$APISIX_MOUNTS" | grep -c "conf/providers" ) || { HAS_PROVIDERS_MOUNT_RC=$?; HAS_PROVIDERS_MOUNT="0"; }
assert_eq "APISIX mounts conf/providers" "1" "$HAS_PROVIDERS_MOUNT"

HAS_COST_CALC_MOUNT_RC=0
HAS_COST_CALC_MOUNT=$(echo "$APISIX_MOUNTS" | grep -c "cost_calc.lua" ) || { HAS_COST_CALC_MOUNT_RC=$?; HAS_COST_CALC_MOUNT="0"; }
assert_eq "APISIX mounts cost_calc.lua" "1" "$HAS_COST_CALC_MOUNT"

HAS_KEY_META_MOUNT_RC=0
HAS_KEY_META_MOUNT=$(echo "$APISIX_MOUNTS" | grep -c "key-meta.lua" ) || { HAS_KEY_META_MOUNT_RC=$?; HAS_KEY_META_MOUNT="0"; }
assert_eq "APISIX mounts key-meta.lua" "1" "$HAS_KEY_META_MOUNT"

HAS_SSE_USAGE_MOUNT_RC=0
HAS_SSE_USAGE_MOUNT=$(echo "$APISIX_MOUNTS" | grep -c "sse-usage.lua" ) || { HAS_SSE_USAGE_MOUNT_RC=$?; HAS_SSE_USAGE_MOUNT="0"; }
assert_eq "APISIX mounts sse-usage.lua" "1" "$HAS_SSE_USAGE_MOUNT"

HAS_OAUTH_AUTH_MOUNT_RC=0
HAS_OAUTH_AUTH_MOUNT=$(echo "$APISIX_MOUNTS" | grep -c "oauth-auth.lua" ) || { HAS_OAUTH_AUTH_MOUNT_RC=$?; HAS_OAUTH_AUTH_MOUNT="0"; }
assert_eq "APISIX mounts oauth-auth.lua" "1" "$HAS_OAUTH_AUTH_MOUNT"

HAS_OAUTH_JWT_MOUNT_RC=0
HAS_OAUTH_JWT_MOUNT=$(echo "$APISIX_MOUNTS" | grep -c "oauth_jwt.lua" ) || { HAS_OAUTH_JWT_MOUNT_RC=$?; HAS_OAUTH_JWT_MOUNT="0"; }
assert_eq "APISIX mounts oauth_jwt.lua" "1" "$HAS_OAUTH_JWT_MOUNT"

HAS_OAUTH_DEVICE_MOUNT_RC=0
HAS_OAUTH_DEVICE_MOUNT=$(echo "$APISIX_MOUNTS" | grep -c "oauth_device.lua" ) || { HAS_OAUTH_DEVICE_MOUNT_RC=$?; HAS_OAUTH_DEVICE_MOUNT="0"; }
assert_eq "APISIX mounts oauth_device.lua" "1" "$HAS_OAUTH_DEVICE_MOUNT"

HAS_OAUTH_STORE_MOUNT_RC=0
HAS_OAUTH_STORE_MOUNT=$(echo "$APISIX_MOUNTS" | grep -c "oauth_store.lua" ) || { HAS_OAUTH_STORE_MOUNT_RC=$?; HAS_OAUTH_STORE_MOUNT="0"; }
assert_eq "APISIX mounts oauth_store.lua" "1" "$HAS_OAUTH_STORE_MOUNT"

HAS_OAUTH_VERIFY_MOUNT_RC=0
HAS_OAUTH_VERIFY_MOUNT=$(echo "$APISIX_MOUNTS" | grep -c "oauth_verify.lua" ) || { HAS_OAUTH_VERIFY_MOUNT_RC=$?; HAS_OAUTH_VERIFY_MOUNT="0"; }
assert_eq "APISIX mounts oauth_verify.lua" "1" "$HAS_OAUTH_VERIFY_MOUNT"

HAS_OAUTH_SESSION_MOUNT_RC=0
HAS_OAUTH_SESSION_MOUNT=$(echo "$APISIX_MOUNTS" | grep -c "oauth_session.lua" ) || { HAS_OAUTH_SESSION_MOUNT_RC=$?; HAS_OAUTH_SESSION_MOUNT="0"; }
assert_eq "APISIX mounts oauth_session.lua" "1" "$HAS_OAUTH_SESSION_MOUNT"

HAS_PROVIDER_SYNC_MOUNT_RC=0
HAS_PROVIDER_SYNC_MOUNT=$(echo "$APISIX_MOUNTS" | grep -c "provider-sync.lua" ) || { HAS_PROVIDER_SYNC_MOUNT_RC=$?; HAS_PROVIDER_SYNC_MOUNT="0"; }
assert_eq "APISIX mounts provider-sync.lua" "1" "$HAS_PROVIDER_SYNC_MOUNT"

HAS_PROVIDER_SYNC_CATALOG_MOUNT_RC=0
HAS_PROVIDER_SYNC_CATALOG_MOUNT=$(echo "$APISIX_MOUNTS" | grep -c "provider_sync_catalog.lua" ) || { HAS_PROVIDER_SYNC_CATALOG_MOUNT_RC=$?; HAS_PROVIDER_SYNC_CATALOG_MOUNT="0"; }
assert_eq "APISIX mounts provider_sync_catalog.lua" "1" "$HAS_PROVIDER_SYNC_CATALOG_MOUNT"
HAS_PROVIDER_SYNC_ALIASES_MOUNT_RC=0
HAS_PROVIDER_SYNC_ALIASES_MOUNT=$(echo "$APISIX_MOUNTS" | grep -c "provider_sync_aliases.lua" ) || { HAS_PROVIDER_SYNC_ALIASES_MOUNT_RC=$?; HAS_PROVIDER_SYNC_ALIASES_MOUNT="0"; }
assert_eq "APISIX mounts provider_sync_aliases.lua" "1" "$HAS_PROVIDER_SYNC_ALIASES_MOUNT"
HAS_PROVIDER_SYNC_CONTRACT_MOUNT_RC=0
HAS_PROVIDER_SYNC_CONTRACT_MOUNT=$(echo "$APISIX_MOUNTS" | grep -c "provider_sync_contract.lua" ) || { HAS_PROVIDER_SYNC_CONTRACT_MOUNT_RC=$?; HAS_PROVIDER_SYNC_CONTRACT_MOUNT="0"; }
assert_eq "APISIX mounts provider_sync_contract.lua" "1" "$HAS_PROVIDER_SYNC_CONTRACT_MOUNT"

HAS_MODEL_REGISTRY_MOUNT_RC=0
HAS_MODEL_REGISTRY_MOUNT=$(echo "$APISIX_MOUNTS" | grep -c "model_registry.lua" ) || { HAS_MODEL_REGISTRY_MOUNT_RC=$?; HAS_MODEL_REGISTRY_MOUNT="0"; }
assert_eq "APISIX mounts model_registry.lua" "1" "$HAS_MODEL_REGISTRY_MOUNT"

HAS_PROVIDER_SYNC_PRICING_MOUNT_RC=0
HAS_PROVIDER_SYNC_PRICING_MOUNT=$(echo "$APISIX_MOUNTS" | grep -c "provider_sync_pricing.lua" ) || { HAS_PROVIDER_SYNC_PRICING_MOUNT_RC=$?; HAS_PROVIDER_SYNC_PRICING_MOUNT="0"; }
assert_eq "APISIX mounts provider_sync_pricing.lua" "1" "$HAS_PROVIDER_SYNC_PRICING_MOUNT"
HAS_PROVIDER_PRICING_MOUNT_RC=0
HAS_PROVIDER_PRICING_MOUNT=$(echo "$APISIX_MOUNTS" | grep -c "provider_pricing.lua" ) || { HAS_PROVIDER_PRICING_MOUNT_RC=$?; HAS_PROVIDER_PRICING_MOUNT="0"; }
assert_eq "APISIX mounts provider_pricing.lua" "1" "$HAS_PROVIDER_PRICING_MOUNT"

APISIX_VOLUME_COUNT=$(echo "$APISIX_MOUNTS" | wc -l | tr -d ' ')
assert_eq "APISIX has 29 volume mounts (5 config + 23 plugins + usefulness)" "29" "$APISIX_VOLUME_COUNT"

CLICKHOUSE_MOUNTS=$(echo "$JSON_DATA" | jq -r '.services.clickhouse.volumes[]')
HAS_INIT_SQL_RC=0
HAS_INIT_SQL=$(echo "$CLICKHOUSE_MOUNTS" | grep -c "clickhouse-init.sql" ) || { HAS_INIT_SQL_RC=$?; HAS_INIT_SQL="0"; }
assert_eq "ClickHouse mounts clickhouse-init.sql" "1" "$HAS_INIT_SQL"
HAS_PROVISION_SH_RC=0
HAS_PROVISION_SH=$(echo "$CLICKHOUSE_MOUNTS" | grep -c "clickhouse-provision.sh" ) || { HAS_PROVISION_SH_RC=$?; HAS_PROVISION_SH="0"; }
assert_eq "ClickHouse mounts provision script (users/grants bootstrap)" "1" "$HAS_PROVISION_SH"
HAS_TIERING_XML_RC=0
HAS_TIERING_XML=$(echo "$CLICKHOUSE_MOUNTS" | grep -c "clickhouse-storage-tiering.xml" ) || { HAS_TIERING_XML_RC=$?; HAS_TIERING_XML="0"; }
assert_eq "ClickHouse mounts storage tiering config" "1" "$HAS_TIERING_XML"
HAS_OPS_ADMIN_XML_RC=0
HAS_OPS_ADMIN_XML=$(echo "$CLICKHOUSE_MOUNTS" | grep -c "ops-admin.xml" ) || { HAS_OPS_ADMIN_XML_RC=$?; HAS_OPS_ADMIN_XML="0"; }
assert_eq "ClickHouse mounts ops_admin XML user" "1" "$HAS_OPS_ADMIN_XML"
HAS_DISABLED_METRIC_LOGS_RC=0
HAS_DISABLED_METRIC_LOGS=$(echo "$CLICKHOUSE_MOUNTS" | grep -c "clickhouse-disable-metric-logs.xml" ) || { HAS_DISABLED_METRIC_LOGS_RC=$?; HAS_DISABLED_METRIC_LOGS="0"; }
assert_eq "ClickHouse disables metric log writers" "1" "$HAS_DISABLED_METRIC_LOGS"
CLICKHOUSE_NO_CHOWN=$(echo "$JSON_DATA" | jq -r '[.services.clickhouse.environment[] | select(. == "CLICKHOUSE_DO_NOT_CHOWN=1")] | length')
assert_eq "ClickHouse skips recursive volume chown" "1" "$CLICKHOUSE_NO_CHOWN"
CLICKHOUSE_NO_ACM=$(echo "$JSON_DATA" | jq '[.services.clickhouse.environment[] | select(. == "CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1")] | length')
assert_eq "ClickHouse default user never gets access management" "0" "$CLICKHOUSE_NO_ACM"
CLICKHOUSE_HC=$(echo "$JSON_DATA" | jq -r '.services.clickhouse.healthcheck.test' | grep -c 'CLICKHOUSE_PASSWORD')
assert_eq "ClickHouse healthcheck authenticates" "1" "$CLICKHOUSE_HC"
CLICKHOUSE_PORTS=$(echo "$JSON_DATA" | jq -c '.services.clickhouse.ports')
assert_eq "ClickHouse publishes loopback HTTP only" '["127.0.0.1:8123:8123"]' "$CLICKHOUSE_PORTS"

VECTOR_MOUNTS=$(echo "$JSON_DATA" | jq -r '.services.vector.volumes[]')
HAS_VECTOR_TOML_RC=0
HAS_VECTOR_TOML=$(echo "$VECTOR_MOUNTS" | grep -c "vector.toml" ) || { HAS_VECTOR_TOML_RC=$?; HAS_VECTOR_TOML="0"; }
assert_eq "Vector mounts vector.toml" "1" "$HAS_VECTOR_TOML"

VECTOR_PORT_18080=$(echo "$JSON_DATA" | jq '(.services.vector.ports // []) | length')
assert_eq "Vector publishes no host ports (exec-only access)" "0" "$VECTOR_PORT_18080"

VECTOR_ENV_FILE=$(echo "$JSON_DATA" | jq '[.services.vector.env_file[] | select(endswith(".env"))] | length')
assert_eq "Vector loads .env (CH_VECTOR_PASSWORD for sink auth)" "1" "$VECTOR_ENV_FILE"

VECTOR_CMD=$(echo "$JSON_DATA" | jq -r '[.services.vector.command[] | select(. == "/etc/vector/vector.toml")] | length')
assert_eq "Vector command specifies vector.toml config" "1" "$VECTOR_CMD"

ETCD_CONTAINER=$(echo "$JSON_DATA" | jq -r '.services.etcd.container_name')
assert_eq "etcd container name is gw-etcd" "gw-etcd" "$ETCD_CONTAINER"

ETCD_PORT=$(echo "$JSON_DATA" | jq '(.services.etcd.ports // []) | length')
assert_eq "etcd publishes no host ports (exec-only access)" "0" "$ETCD_PORT"

ETCD_NETWORK=$(echo "$JSON_DATA" | jq '[.services.etcd.networks | keys[] | select(. == "gw-etcd")] | length')
assert_eq "etcd isolated on gw-etcd network" "1" "$ETCD_NETWORK"

ETCD_HC_AUTH=$(echo "$JSON_DATA" | jq -r '.services.etcd.healthcheck.test' | grep -c 'ETCD_ROOT_PASSWORD')
assert_eq "etcd healthcheck carries root credentials (post-RBAC)" "1" "$ETCD_HC_AUTH"

MIGRATE_DSN_USER=$(echo "$JSON_DATA" | jq -r '[.services.migrate.entrypoint[] | select(startswith("-database=clickhouse://"))][0]' | grep -c 'username=migrator&password=${CH_MIGRATOR_PASSWORD}')
assert_eq "Migrations run as least-privilege migrator user (query-param DSN; URL userinfo unsupported by the driver)" "1" "$MIGRATE_DSN_USER"

APISIX_NETWORKS=$(echo "$JSON_DATA" | jq -c '[.services.apisix.networks | keys[]] | sort')
assert_eq "APISIX attached to exactly the five trust boundaries + dataops" '["dataops","gw-ch","gw-etcd","gw-ingest","gw-metrics","gw-secrets"]' "$APISIX_NETWORKS"

GW_CH_SUBNET=$(echo "$JSON_DATA" | jq -r '.networks["gw-ch"].ipam.config[0].subnet')
assert_eq "gw-ch static subnet" "10.99.10.0/24" "$GW_CH_SUBNET"

GW_ETCD_SUBNET=$(echo "$JSON_DATA" | jq -r '.networks["gw-etcd"].ipam.config[0].subnet')
assert_eq "gw-etcd static subnet" "10.99.20.0/24" "$GW_ETCD_SUBNET"

GW_SECRETS_SUBNET=$(echo "$JSON_DATA" | jq -r '.networks["gw-secrets"].ipam.config[0].subnet')
assert_eq "gw-secrets static subnet" "10.99.30.0/24" "$GW_SECRETS_SUBNET"

GW_METRICS_SUBNET=$(echo "$JSON_DATA" | jq -r '.networks["gw-metrics"].ipam.config[0].subnet')
assert_eq "gw-metrics static subnet" "10.99.40.0/24" "$GW_METRICS_SUBNET"

GW_INGEST_SUBNET=$(echo "$JSON_DATA" | jq -r '.networks["gw-ingest"].ipam.config[0].subnet')
assert_eq "gw-ingest static subnet" "10.99.50.0/24" "$GW_INGEST_SUBNET"

GW_EDGE_SUBNET=$(echo "$JSON_DATA" | jq -r '.networks["gw-edge"].ipam.config[0].subnet')
assert_eq "gw-edge static subnet" "10.99.60.0/24" "$GW_EDGE_SUBNET"

HAS_DATAOPS=$(echo "$JSON_DATA" | jq '.networks | has("dataops")')
assert_eq "Networks has dataops" "true" "$HAS_DATAOPS"

HAS_PROM_VOLUME=$(echo "$JSON_DATA" | jq '.volumes | has("prometheus-data")')
assert_eq "Has prometheus-data volume" "true" "$HAS_PROM_VOLUME"

HAS_GRAFANA_VOLUME=$(echo "$JSON_DATA" | jq '.volumes | has("grafana-data")')
assert_eq "Has grafana-data volume" "true" "$HAS_GRAFANA_VOLUME"

HAS_ETCD_VOLUME=$(echo "$JSON_DATA" | jq '.volumes | has("etcd-data")')
assert_eq "Has etcd-data volume" "true" "$HAS_ETCD_VOLUME"

APISIX_ENV_FILE=$(echo "$JSON_DATA" | jq -r '.services.apisix.env_file[]')
HAS_ENV_FILE_RC=0
HAS_ENV_FILE=$(echo "$APISIX_ENV_FILE" | grep -c "\.env" ) || { HAS_ENV_FILE_RC=$?; HAS_ENV_FILE="0"; }
assert_eq "APISIX has env_file pointing to .env" "1" "$HAS_ENV_FILE"

APISIX_DEPS=$(echo "$JSON_DATA" | jq -r '.services.apisix.depends_on[]')
HAS_OPENBAO_DEP_RC=0
HAS_OPENBAO_DEP=$(echo "$APISIX_DEPS" | grep -c "openbao" ) || { HAS_OPENBAO_DEP_RC=$?; HAS_OPENBAO_DEP="0"; }
assert_eq "APISIX depends on openbao" "1" "$HAS_OPENBAO_DEP"

HAS_ETCD_DEP_RC=0
HAS_ETCD_DEP=$(echo "$APISIX_DEPS" | grep -c "etcd" ) || { HAS_ETCD_DEP_RC=$?; HAS_ETCD_DEP="0"; }
assert_eq "APISIX depends on etcd" "1" "$HAS_ETCD_DEP"

summary
