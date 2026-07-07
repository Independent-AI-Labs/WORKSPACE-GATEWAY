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
    echo "test_config_yaml.sh: $pass passed, $fail failed"
    if [ "$fail" -gt 0 ]; then
        exit 1
    fi
}

CONFIG_YAML="$REPO_ROOT/conf/config.yaml"

JSON_DATA=$(yaml_to_json "$CONFIG_YAML")
ret=$?
if [ "$ret" -ne 0 ]; then
    echo "[FAIL] Valid YAML"
    fail=$((fail + 1))
    summary
fi

assert_eq "Valid YAML" "ok" "ok"

DEPLOY_ROLE=$(echo "$JSON_DATA" | jq -r '.deployment.role')
assert_eq "deployment.role is data_plane" "data_plane" "$DEPLOY_ROLE"

DEPLOY_PROVIDER=$(echo "$JSON_DATA" | jq -r '.deployment.role_data_plane.config_provider')
assert_eq "deployment.role_data_plane.config_provider is yaml" "yaml" "$DEPLOY_PROVIDER"

PLUGINS_REDACT=$(echo "$JSON_DATA" | jq '[.plugins[] | select(. == "redact")] | length')
assert_eq "redact in plugins list" "1" "$PLUGINS_REDACT"

PLUGINS_KEY_RESOLVER=$(echo "$JSON_DATA" | jq '[.plugins[] | select(. == "key-resolver")] | length')
assert_eq "key-resolver in plugins list" "1" "$PLUGINS_KEY_RESOLVER"

PLUGINS_KEY_META=$(echo "$JSON_DATA" | jq '[.plugins[] | select(. == "key-meta")] | length')
assert_eq "key-meta in plugins list" "1" "$PLUGINS_KEY_META"

PLUGINS_COST_CALC=$(echo "$JSON_DATA" | jq '[.plugins[] | select(. == "cost_calc")] | length')
assert_eq "cost_calc intentionally NOT in plugins list (library, not plugin)" "0" "$PLUGINS_COST_CALC"

PLUGINS_SSE_USAGE=$(echo "$JSON_DATA" | jq '[.plugins[] | select(. == "sse-usage")] | length')
assert_eq "sse-usage in plugins list" "1" "$PLUGINS_SSE_USAGE"

PLUGINS_GATEWAY_AUTH=$(echo "$JSON_DATA" | jq '[.plugins[] | select(. == "gateway-auth")] | length')
assert_eq "gateway-auth removed from plugins list" "0" "$PLUGINS_GATEWAY_AUTH"

PLUGINS_KEYAUTH=$(echo "$JSON_DATA" | jq '[.plugins[] | select(. == "key-auth")] | length')
assert_eq "key-auth removed from plugins list" "0" "$PLUGINS_KEYAUTH"

HAS_REDACT_DICT=$(echo "$JSON_DATA" | jq '.nginx_config.http.custom_lua_shared_dict | has("redact_state")')
assert_eq "custom_lua_shared_dict has redact_state" "true" "$HAS_REDACT_DICT"

HAS_KEY_CACHE=$(echo "$JSON_DATA" | jq '.nginx_config.http.custom_lua_shared_dict | has("key_cache")')
assert_eq "custom_lua_shared_dict has key_cache" "true" "$HAS_KEY_CACHE"

HAS_GATEWAY_CACHE=$(echo "$JSON_DATA" | jq '.nginx_config.http.custom_lua_shared_dict | has("gateway-cache")')
assert_eq "custom_lua_shared_dict has gateway-cache" "true" "$HAS_GATEWAY_CACHE"

GATEWAY_CACHE_SIZE=$(echo "$JSON_DATA" | jq -r '.nginx_config.http.custom_lua_shared_dict["gateway-cache"]')
assert_eq "gateway-cache shared dict size is 2m" "2m" "$GATEWAY_CACHE_SIZE"

PLUGINS_RATE=$(echo "$JSON_DATA" | jq '[.plugins[] | select(. == "ai-rate-limiting")] | length')
assert_eq "ai-rate-limiting in plugins list" "1" "$PLUGINS_RATE"

PLUGINS_PROM=$(echo "$JSON_DATA" | jq '[.plugins[] | select(. == "prometheus")] | length')
assert_eq "prometheus in plugins list" "1" "$PLUGINS_PROM"

PLUGINS_LOGGER=$(echo "$JSON_DATA" | jq '[.plugins[] | select(. == "http-logger")] | length')
assert_eq "http-logger in plugins list" "1" "$PLUGINS_LOGGER"

PLUGINS_BUFFER=$(echo "$JSON_DATA" | jq '[.plugins[] | select(. == "proxy-buffering")] | length')
assert_eq "proxy-buffering in plugins list" "1" "$PLUGINS_BUFFER"

NO_SEMCACHE=$(echo "$JSON_DATA" | jq '.nginx_config.http.custom_lua_shared_dict | has("semcache_state")')
assert_eq "semcache_state removed from shared dict" "false" "$NO_SEMCACHE"

NO_AI_PROXY=$(echo "$JSON_DATA" | jq '[.plugins[] | select(. == "ai-proxy")] | length')
assert_eq "ai-proxy removed from plugins list" "0" "$NO_AI_PROXY"

NO_AI_PROXY_MULTI=$(echo "$JSON_DATA" | jq '[.plugins[] | select(. == "ai-proxy-multi")] | length')
assert_eq "ai-proxy-multi removed from plugins list" "0" "$NO_AI_PROXY_MULTI"

PROM_EXPORT_IP=$(echo "$JSON_DATA" | jq -r '.plugin_attr.prometheus.export_addr.ip')
assert_eq "prometheus export_addr ip is 0.0.0.0" "0.0.0.0" "$PROM_EXPORT_IP"

PROM_EXPORT_PORT=$(echo "$JSON_DATA" | jq -r '.plugin_attr.prometheus.export_addr.port')
assert_eq "prometheus export_addr port is 9100" "9100" "$PROM_EXPORT_PORT"

HAS_ENVS=$(echo "$JSON_DATA" | jq '.nginx_config.envs | index("OPENCODE_API_KEY") != null')
assert_eq "nginx_config.envs contains OPENCODE_API_KEY" "true" "$HAS_ENVS"

HAS_OPENBAO_ENV=$(echo "$JSON_DATA" | jq '.nginx_config.envs | index("OPENBAO_TOKEN") != null')
assert_eq "nginx_config.envs contains OPENBAO_TOKEN" "true" "$HAS_OPENBAO_ENV"

summary