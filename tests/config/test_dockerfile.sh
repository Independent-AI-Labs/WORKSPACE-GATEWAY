#!/bin/bash
set -euo pipefail

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
    _SELF="$SHG_SCRIPT_PATH"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
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
        echo "[FAIL] $desc -- expected: $expected, actual: $actual"
        fail=$((fail + 1))
    fi
}

summary() {
    echo ""
    echo "test_dockerfile.sh: $pass passed, $fail failed"
    if [ "$fail" -gt 0 ]; then
        exit 1
    fi
}

DOCKERFILE="$REPO_ROOT/res/docker/Dockerfile.apisix"

HAS_BASE_IMAGE_RC=0
HAS_BASE_IMAGE=$(grep -c 'FROM apache/apisix:3.17.0-debian' "$DOCKERFILE" ) || { HAS_BASE_IMAGE_RC=$?; HAS_BASE_IMAGE="0"; }
assert_eq "Base image is apache/apisix:3.17.0-debian" "1" "$HAS_BASE_IMAGE"

HAS_CUSTOM_PLUGINS_RC=0
HAS_CUSTOM_PLUGINS=$(grep -c 'plugins/custom/' "$DOCKERFILE" ) || { HAS_CUSTOM_PLUGINS_RC=$?; HAS_CUSTOM_PLUGINS="0"; }
assert_eq "Copies plugins/custom/ (generic OAuth plugin set)" "22" "$HAS_CUSTOM_PLUGINS"

HAS_MODEL_REGISTRY_RC=0
HAS_MODEL_REGISTRY=$(grep -c 'model_registry.lua' "$DOCKERFILE" ) || { HAS_MODEL_REGISTRY_RC=$?; HAS_MODEL_REGISTRY="0"; }
assert_eq "Copies model_registry.lua" "1" "$HAS_MODEL_REGISTRY"

HAS_KEY_RESOLVER_RC=0
HAS_KEY_RESOLVER=$(grep -c 'key-resolver.lua' "$DOCKERFILE" ) || { HAS_KEY_RESOLVER_RC=$?; HAS_KEY_RESOLVER="0"; }
assert_eq "Copies key-resolver.lua" "1" "$HAS_KEY_RESOLVER"

HAS_KEY_META_RC=0
HAS_KEY_META=$(grep -c 'key-meta.lua' "$DOCKERFILE" ) || { HAS_KEY_META_RC=$?; HAS_KEY_META="0"; }
assert_eq "Copies key-meta.lua" "1" "$HAS_KEY_META"

HAS_OAUTH_AUTH_RC=0
HAS_OAUTH_AUTH=$(grep -c 'oauth-auth.lua' "$DOCKERFILE" ) || { HAS_OAUTH_AUTH_RC=$?; HAS_OAUTH_AUTH="0"; }
assert_eq "Copies oauth-auth.lua" "1" "$HAS_OAUTH_AUTH"

HAS_OAUTH_JWT_RC=0
HAS_OAUTH_JWT=$(grep -c 'oauth_jwt.lua' "$DOCKERFILE" ) || { HAS_OAUTH_JWT_RC=$?; HAS_OAUTH_JWT="0"; }
assert_eq "Copies oauth_jwt.lua" "1" "$HAS_OAUTH_JWT"

HAS_OAUTH_DEVICE_RC=0
HAS_OAUTH_DEVICE=$(grep -c 'oauth_device.lua' "$DOCKERFILE" ) || { HAS_OAUTH_DEVICE_RC=$?; HAS_OAUTH_DEVICE="0"; }
assert_eq "Copies oauth_device.lua" "1" "$HAS_OAUTH_DEVICE"

HAS_OAUTH_STORE_RC=0
HAS_OAUTH_STORE=$(grep -c 'oauth_store.lua' "$DOCKERFILE" ) || { HAS_OAUTH_STORE_RC=$?; HAS_OAUTH_STORE="0"; }
assert_eq "Copies oauth_store.lua" "1" "$HAS_OAUTH_STORE"

HAS_OAUTH_SESSION_RC=0
HAS_OAUTH_SESSION=$(grep -c 'oauth_session.lua' "$DOCKERFILE" ) || { HAS_OAUTH_SESSION_RC=$?; HAS_OAUTH_SESSION="0"; }
assert_eq "Copies oauth_session.lua" "1" "$HAS_OAUTH_SESSION"

HAS_PROVIDER_SYNC_RC=0
HAS_PROVIDER_SYNC=$(grep -c 'provider-sync.lua' "$DOCKERFILE" ) || { HAS_PROVIDER_SYNC_RC=$?; HAS_PROVIDER_SYNC="0"; }
assert_eq "Copies provider-sync.lua" "1" "$HAS_PROVIDER_SYNC"

HAS_PROVIDER_SYNC_CATALOG_RC=0
HAS_PROVIDER_SYNC_CATALOG=$(grep -c 'provider_sync_catalog.lua' "$DOCKERFILE" ) || { HAS_PROVIDER_SYNC_CATALOG_RC=$?; HAS_PROVIDER_SYNC_CATALOG="0"; }
assert_eq "Copies provider_sync_catalog.lua" "1" "$HAS_PROVIDER_SYNC_CATALOG"
HAS_PROVIDER_SYNC_ALIASES_RC=0
HAS_PROVIDER_SYNC_ALIASES=$(grep -c 'provider_sync_aliases.lua' "$DOCKERFILE" ) || { HAS_PROVIDER_SYNC_ALIASES_RC=$?; HAS_PROVIDER_SYNC_ALIASES="0"; }
assert_eq "Copies provider_sync_aliases.lua" "1" "$HAS_PROVIDER_SYNC_ALIASES"
HAS_PROVIDER_SYNC_CONTRACT_RC=0
HAS_PROVIDER_SYNC_CONTRACT=$(grep -c 'provider_sync_contract.lua' "$DOCKERFILE" ) || { HAS_PROVIDER_SYNC_CONTRACT_RC=$?; HAS_PROVIDER_SYNC_CONTRACT="0"; }
assert_eq "Copies provider_sync_contract.lua" "1" "$HAS_PROVIDER_SYNC_CONTRACT"
HAS_PROVIDER_PRICING_RC=0
HAS_PROVIDER_PRICING=$(grep -c 'provider_pricing.lua' "$DOCKERFILE" ) || { HAS_PROVIDER_PRICING_RC=$?; HAS_PROVIDER_PRICING="0"; }
assert_eq "Copies provider_pricing.lua" "1" "$HAS_PROVIDER_PRICING"

HAS_SSE_USAGE_RC=0
HAS_SSE_USAGE=$(grep -c 'sse-usage.lua' "$DOCKERFILE" ) || { HAS_SSE_USAGE_RC=$?; HAS_SSE_USAGE="0"; }
assert_eq "Copies sse-usage.lua" "1" "$HAS_SSE_USAGE"

HAS_SSE_USAGE_LIB_RC=0
HAS_SSE_USAGE_LIB=$(grep -c 'sse_usage_lib.lua' "$DOCKERFILE" ) || { HAS_SSE_USAGE_LIB_RC=$?; HAS_SSE_USAGE_LIB="0"; }
assert_eq "Copies sse_usage_lib.lua" "1" "$HAS_SSE_USAGE_LIB"

HAS_COST_CALC_RC=0
HAS_COST_CALC=$(grep -c 'cost_calc.lua' "$DOCKERFILE" ) || { HAS_COST_CALC_RC=$?; HAS_COST_CALC="0"; }
assert_eq "Copies cost_calc.lua" "1" "$HAS_COST_CALC"

HAS_REDACT_RC=0
HAS_REDACT=$(grep -c 'redact\.lua' "$DOCKERFILE" ) || { HAS_REDACT_RC=$?; HAS_REDACT="0"; }
assert_eq "Copies redact.lua" "1" "$HAS_REDACT"

NO_GATEWAY_AUTH_RC=0
NO_GATEWAY_AUTH=$(grep -c 'gateway-auth.lua' "$DOCKERFILE" ) || { NO_GATEWAY_AUTH_RC=$?; NO_GATEWAY_AUTH="0"; }
assert_eq "gateway-auth.lua removed from Dockerfile" "0" "$NO_GATEWAY_AUTH"

HAS_CONFIG_YAML_RC=0
HAS_CONFIG_YAML=$(grep -c 'config.yaml' "$DOCKERFILE" ) || { HAS_CONFIG_YAML_RC=$?; HAS_CONFIG_YAML="0"; }
assert_eq "Copies conf/config.yaml" "1" "$HAS_CONFIG_YAML"

HAS_REDACT_PATTERNS_RC=0
HAS_REDACT_PATTERNS=$(grep -c 'redact-patterns.json' "$DOCKERFILE" ) || { HAS_REDACT_PATTERNS_RC=$?; HAS_REDACT_PATTERNS="0"; }
assert_eq "Copies conf/redact-patterns.json" "1" "$HAS_REDACT_PATTERNS"

HAS_PROVIDERS_RC=0
HAS_PROVIDERS=$(grep -c 'conf/providers' "$DOCKERFILE" ) || { HAS_PROVIDERS_RC=$?; HAS_PROVIDERS="0"; }
assert_eq "Copies conf/providers" "1" "$HAS_PROVIDERS"

summary
