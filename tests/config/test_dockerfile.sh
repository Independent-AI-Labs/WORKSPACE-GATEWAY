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

HAS_BASE_IMAGE=$(grep -c 'FROM apache/apisix:3.17.0-debian' "$DOCKERFILE" || true)
assert_eq "Base image is apache/apisix:3.17.0-debian" "1" "$HAS_BASE_IMAGE"

HAS_CUSTOM_PLUGINS=$(grep -c 'plugins/custom/' "$DOCKERFILE" || true)
assert_eq "Copies plugins/custom/ (key-resolver + key-meta + sse-usage + sse_usage_lib + cost_calc + redact + redact_lib)" "7" "$HAS_CUSTOM_PLUGINS"

HAS_KEY_RESOLVER=$(grep -c 'key-resolver.lua' "$DOCKERFILE" || true)
assert_eq "Copies key-resolver.lua" "1" "$HAS_KEY_RESOLVER"

HAS_KEY_META=$(grep -c 'key-meta.lua' "$DOCKERFILE" || true)
assert_eq "Copies key-meta.lua" "1" "$HAS_KEY_META"

HAS_SSE_USAGE=$(grep -c 'sse-usage.lua' "$DOCKERFILE" || true)
assert_eq "Copies sse-usage.lua" "1" "$HAS_SSE_USAGE"

HAS_SSE_USAGE_LIB=$(grep -c 'sse_usage_lib.lua' "$DOCKERFILE" || true)
assert_eq "Copies sse_usage_lib.lua" "1" "$HAS_SSE_USAGE_LIB"

HAS_COST_CALC=$(grep -c 'cost_calc.lua' "$DOCKERFILE" || true)
assert_eq "Copies cost_calc.lua" "1" "$HAS_COST_CALC"

HAS_REDACT=$(grep -c 'redact\.lua' "$DOCKERFILE" || true)
assert_eq "Copies redact.lua" "1" "$HAS_REDACT"

NO_GATEWAY_AUTH=$(grep -c 'gateway-auth.lua' "$DOCKERFILE" || true)
assert_eq "gateway-auth.lua removed from Dockerfile" "0" "$NO_GATEWAY_AUTH"

HAS_CONFIG_YAML=$(grep -c 'config.yaml' "$DOCKERFILE" || true)
assert_eq "Copies conf/config.yaml" "1" "$HAS_CONFIG_YAML"

HAS_REDACT_PATTERNS=$(grep -c 'redact-patterns.json' "$DOCKERFILE" || true)
assert_eq "Copies conf/redact-patterns.json" "1" "$HAS_REDACT_PATTERNS"

summary