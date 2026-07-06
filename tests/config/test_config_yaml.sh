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
    echo "test_config_yaml.sh: $pass passed, $fail failed"
    if [ "$fail" -gt 0 ]; then
        exit 1
    fi
}

CONFIG_YAML="$REPO_ROOT/conf/config.yaml"

JSON_DATA=$(python3 -c "
import yaml, json
with open('$CONFIG_YAML') as f:
    data = yaml.safe_load(f)
print(json.dumps(data))
")
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

EXTRA_LUA_PATH=$(echo "$JSON_DATA" | jq -r '.apisix.extra_lua_path')
HAS_CUSTOM=$(echo "$EXTRA_LUA_PATH" | grep -c "plugins/custom" || true)
assert_eq "extra_lua_path includes custom plugins path" "1" "$HAS_CUSTOM"

PLUGINS_REDACT=$(echo "$JSON_DATA" | jq '[.plugins[] | select(. == "redact")] | length')
assert_eq "redact in plugins list" "1" "$PLUGINS_REDACT"

PLUGINS_KEYAUTH=$(echo "$JSON_DATA" | jq '[.plugins[] | select(. == "key-auth")] | length')
assert_eq "key-auth in plugins list" "1" "$PLUGINS_KEYAUTH"

HAS_REDACT_DICT=$(echo "$JSON_DATA" | jq '.apisix.lua_shared_dict | has("redact_state")')
assert_eq "lua_shared_dict has redact_state" "true" "$HAS_REDACT_DICT"

summary