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
assert_eq "Copies plugins/custom/ (redact.lua + redact_lib.lua)" "2" "$HAS_CUSTOM_PLUGINS"

HAS_CONFIG_YAML=$(grep -c 'config.yaml' "$DOCKERFILE" || true)
assert_eq "Copies conf/config.yaml" "1" "$HAS_CONFIG_YAML"

HAS_REDACT_PATTERNS=$(grep -c 'redact-patterns.json' "$DOCKERFILE" || true)
assert_eq "Copies conf/redact-patterns.json" "1" "$HAS_REDACT_PATTERNS"

summary