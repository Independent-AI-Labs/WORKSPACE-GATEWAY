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
    echo "test_apisix_yaml.sh: $pass passed, $fail failed"
    if [ "$fail" -gt 0 ]; then
        exit 1
    fi
}

APISIX_YAML="$REPO_ROOT/conf/apisix.yaml"

JSON_DATA=$(python3 -c "
import yaml, json
with open('$APISIX_YAML') as f:
    data = yaml.safe_load(f)
print(json.dumps(data))
")
ret=$?
if [ "$ret" -ne 0 ]; then
    echo "[FAIL] Valid YAML (parseable)"
    fail=$((fail + 1))
    summary
fi

assert_eq "Valid YAML (parseable)" "ok" "ok"

ROUTE_COUNT=$(echo "$JSON_DATA" | jq '.routes | length')
assert_eq "Exactly 1 route" "1" "$ROUTE_COUNT"

ROUTE_ID=$(echo "$JSON_DATA" | jq -r '.routes[0].id')
assert_eq "Route id is relay-zen" "relay-zen" "$ROUTE_ID"

ROUTE_URI=$(echo "$JSON_DATA" | jq -r '.routes[0].uri')
assert_eq "Route uri is /zen/*" "/zen/*" "$ROUTE_URI"

UPSTREAM_SCHEME=$(echo "$JSON_DATA" | jq -r '.routes[0].upstream.scheme')
assert_eq "Upstream scheme is https" "https" "$UPSTREAM_SCHEME"

UPSTREAM_NODE=$(echo "$JSON_DATA" | jq -r '.routes[0].upstream.nodes | keys[0]')
assert_eq "Upstream node is opencode.ai:443" "opencode.ai:443" "$UPSTREAM_NODE"

HAS_PROXY_REWRITE=$(echo "$JSON_DATA" | jq '.routes[0].plugins | has("proxy-rewrite")')
assert_eq "No proxy-rewrite plugin" "false" "$HAS_PROXY_REWRITE"

HAS_KEY_AUTH=$(echo "$JSON_DATA" | jq '.routes[0].plugins | has("gateway-auth")')
assert_eq "gateway-auth plugin present" "true" "$HAS_KEY_AUTH"

GATEWAY_AUTH_MODE=$(echo "$JSON_DATA" | jq -r '.routes[0].plugins["gateway-auth"].mode')
assert_eq "gateway-auth mode is inject" "inject" "$GATEWAY_AUTH_MODE"

GATEWAY_AUTH_KEY=$(echo "$JSON_DATA" | jq -r '.routes[0].plugins["gateway-auth"].gateway_key')
assert_eq "gateway-auth gateway_key is opencode-gateway-key" "opencode-gateway-key" "$GATEWAY_AUTH_KEY"

HAS_AI_RATE=$(echo "$JSON_DATA" | jq '.routes[0].plugins | has("ai-rate-limiting")')
assert_eq "ai-rate-limiting plugin present" "true" "$HAS_AI_RATE"

HAS_PROMETHEUS=$(echo "$JSON_DATA" | jq '.routes[0].plugins | has("prometheus")')
assert_eq "prometheus plugin present" "true" "$HAS_PROMETHEUS"

HAS_HTTP_LOGGER=$(echo "$JSON_DATA" | jq '.routes[0].plugins | has("http-logger")')
assert_eq "http-logger plugin present" "true" "$HAS_HTTP_LOGGER"

HAS_PROXY_BUFFERING=$(echo "$JSON_DATA" | jq '.routes[0].plugins | has("proxy-buffering")')
assert_eq "proxy-buffering plugin present" "true" "$HAS_PROXY_BUFFERING"

HAS_REDACT=$(echo "$JSON_DATA" | jq '.routes[0].plugins | has("redact")')
assert_eq "redact plugin present" "true" "$HAS_REDACT"

HAS_NO_KEY_AUTH=$(echo "$JSON_DATA" | jq '.routes[0].plugins | has("key-auth")')
assert_eq "key-auth plugin removed" "false" "$HAS_NO_KEY_AUTH"

NO_CONSUMERS=$(echo "$JSON_DATA" | jq 'has("consumers")')
assert_eq "No consumers section (gateway-auth replaces key-auth)" "false" "$NO_CONSUMERS"

HTTP_LOGGER_URI=$(echo "$JSON_DATA" | jq -r '.routes[0].plugins["http-logger"].uri')
assert_eq "http-logger uri is http://vector:8080/ingest" "http://vector:8080/ingest" "$HTTP_LOGGER_URI"

HAS_LOG_FORMAT=$(echo "$JSON_DATA" | jq '.routes[0].plugins["http-logger"] | has("log_format")')
assert_eq "http-logger has no log_format (uses default format)" "false" "$HAS_LOG_FORMAT"

INCLUDE_REQ_BODY=$(echo "$JSON_DATA" | jq -r '.routes[0].plugins["http-logger"].include_req_body')
assert_eq "http-logger include_req_body is true" "true" "$INCLUDE_REQ_BODY"

INCLUDE_RESP_BODY=$(echo "$JSON_DATA" | jq -r '.routes[0].plugins["http-logger"].include_resp_body')
assert_eq "http-logger include_resp_body is true" "true" "$INCLUDE_RESP_BODY"

MAX_REQ_BODY=$(echo "$JSON_DATA" | jq -r '.routes[0].plugins["http-logger"].max_req_body_bytes')
assert_eq "http-logger max_req_body_bytes is 8192" "8192" "$MAX_REQ_BODY"

MAX_RESP_BODY=$(echo "$JSON_DATA" | jq -r '.routes[0].plugins["http-logger"].max_resp_body_bytes')
assert_eq "http-logger max_resp_body_bytes is 8192" "8192" "$MAX_RESP_BODY"

summary