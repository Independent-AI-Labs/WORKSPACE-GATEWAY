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
    echo "test_apisix_yaml.sh: $pass passed, $fail failed"
    if [ "$fail" -gt 0 ]; then
        exit 1
    fi
}

APISIX_YAML="$REPO_ROOT/conf/apisix.yaml"

JSON_DATA=$(yaml_to_json "$APISIX_YAML")
ret=$?
if [ "$ret" -ne 0 ]; then
    echo "[FAIL] Valid YAML (parseable)"
    fail=$((fail + 1))
    summary
fi

assert_eq "Valid YAML (parseable)" "ok" "ok"

ROUTE_COUNT=$(echo "$JSON_DATA" | jq '.routes | length')
assert_eq "Exactly 2 routes" "2" "$ROUTE_COUNT"

# --- relay-opencode (passthrough, no key-resolver) ---
OC_ROUTE=$(echo "$JSON_DATA" | jq -c '[.routes[] | select(.id == "relay-opencode")][0]')

OC_ID=$(echo "$OC_ROUTE" | jq -r '.id')
assert_eq "relay-opencode: id is relay-opencode" "relay-opencode" "$OC_ID"

OC_URI=$(echo "$OC_ROUTE" | jq -r '.uri')
assert_eq "relay-opencode: uri is /opencode/*" "/opencode/*" "$OC_URI"

OC_SCHEME=$(echo "$OC_ROUTE" | jq -r '.upstream.scheme')
assert_eq "relay-opencode: upstream scheme is https" "https" "$OC_SCHEME"

OC_NODE=$(echo "$OC_ROUTE" | jq -r '.upstream.nodes | keys[0]')
assert_eq "relay-opencode: upstream node is opencode.ai:443" "opencode.ai:443" "$OC_NODE"

OC_HAS_KEY_RESOLVER=$(echo "$OC_ROUTE" | jq '.plugins | has("key-resolver")')
assert_eq "relay-opencode: no key-resolver (passthrough)" "false" "$OC_HAS_KEY_RESOLVER"

OC_HAS_PROXY_REWRITE=$(echo "$OC_ROUTE" | jq '.plugins | has("proxy-rewrite")')
assert_eq "relay-opencode: proxy-rewrite present" "true" "$OC_HAS_PROXY_REWRITE"

OC_REWRITE_REGEX=$(echo "$OC_ROUTE" | jq -r '.plugins["proxy-rewrite"].regex_uri[0]')
assert_eq "relay-opencode: proxy-rewrite regex strips /opencode/" "^/opencode/(.*)" "$OC_REWRITE_REGEX"

OC_REWRITE_REPLACE=$(echo "$OC_ROUTE" | jq -r '.plugins["proxy-rewrite"].regex_uri[1]')
assert_eq "relay-opencode: proxy-rewrite replacement is /zen/go/" '/zen/go/$1' "$OC_REWRITE_REPLACE"

OC_HAS_GATEWAY_AUTH=$(echo "$OC_ROUTE" | jq '.plugins | has("gateway-auth")')
assert_eq "relay-opencode: gateway-auth plugin removed" "false" "$OC_HAS_GATEWAY_AUTH"

OC_HAS_SSE_USAGE=$(echo "$OC_ROUTE" | jq '.plugins | has("sse-usage")')
assert_eq "relay-opencode: sse-usage plugin present" "true" "$OC_HAS_SSE_USAGE"

OC_HAS_AI_RATE=$(echo "$OC_ROUTE" | jq '.plugins | has("ai-rate-limiting")')
assert_eq "relay-opencode: ai-rate-limiting plugin present" "true" "$OC_HAS_AI_RATE"

OC_HAS_PROMETHEUS=$(echo "$OC_ROUTE" | jq '.plugins | has("prometheus")')
assert_eq "relay-opencode: prometheus plugin present" "true" "$OC_HAS_PROMETHEUS"

OC_HAS_HTTP_LOGGER=$(echo "$OC_ROUTE" | jq '.plugins | has("http-logger")')
assert_eq "relay-opencode: http-logger plugin present" "true" "$OC_HAS_HTTP_LOGGER"

OC_HAS_PROXY_BUFFERING=$(echo "$OC_ROUTE" | jq '.plugins | has("proxy-buffering")')
assert_eq "relay-opencode: proxy-buffering plugin present" "true" "$OC_HAS_PROXY_BUFFERING"

OC_HAS_REDACT=$(echo "$OC_ROUTE" | jq '.plugins | has("redact")')
assert_eq "relay-opencode: redact plugin present" "true" "$OC_HAS_REDACT"

# --- relay-opencode-federated (virtual key, key-resolver + proxy-rewrite) ---
FED_ROUTE=$(echo "$JSON_DATA" | jq -c '[.routes[] | select(.id == "relay-opencode-federated")][0]')

FED_ID=$(echo "$FED_ROUTE" | jq -r '.id')
assert_eq "relay-opencode-federated: id is relay-opencode-federated" "relay-opencode-federated" "$FED_ID"

FED_URI=$(echo "$FED_ROUTE" | jq -r '.uri')
assert_eq "relay-opencode-federated: uri is /opencode_federated/*" "/opencode_federated/*" "$FED_URI"

FED_SCHEME=$(echo "$FED_ROUTE" | jq -r '.upstream.scheme')
assert_eq "relay-opencode-federated: upstream scheme is https" "https" "$FED_SCHEME"

FED_NODE=$(echo "$FED_ROUTE" | jq -r '.upstream.nodes | keys[0]')
assert_eq "relay-opencode-federated: upstream node is opencode.ai:443" "opencode.ai:443" "$FED_NODE"

FED_HAS_KEY_RESOLVER=$(echo "$FED_ROUTE" | jq '.plugins | has("key-resolver")')
assert_eq "relay-opencode-federated: key-resolver plugin present" "true" "$FED_HAS_KEY_RESOLVER"

FED_HAS_PROXY_REWRITE=$(echo "$FED_ROUTE" | jq '.plugins | has("proxy-rewrite")')
assert_eq "relay-opencode-federated: proxy-rewrite plugin present" "true" "$FED_HAS_PROXY_REWRITE"

FED_REWRITE_REGEX=$(echo "$FED_ROUTE" | jq -r '.plugins["proxy-rewrite"].regex_uri[0]')
assert_eq "relay-opencode-federated: proxy-rewrite regex strips /opencode_federated/" "^/opencode_federated/(.*)" "$FED_REWRITE_REGEX"

FED_REWRITE_REPLACE=$(echo "$FED_ROUTE" | jq -r '.plugins["proxy-rewrite"].regex_uri[1]')
assert_eq "relay-opencode-federated: proxy-rewrite replacement is /zen/go/" '/zen/go/$1' "$FED_REWRITE_REPLACE"

FED_KEY_RESOLVER_ADDR=$(echo "$FED_ROUTE" | jq -r '.plugins["key-resolver"].openbao_addr')
assert_eq "relay-opencode-federated: key-resolver openbao_addr is http://openbao:8200" "http://openbao:8200" "$FED_KEY_RESOLVER_ADDR"

FED_KEY_RESOLVER_PREFIX=$(echo "$FED_ROUTE" | jq -r '.plugins["key-resolver"].virtual_key_prefix')
assert_eq "relay-opencode-federated: key-resolver virtual_key_prefix is vgw-" "vgw-" "$FED_KEY_RESOLVER_PREFIX"

FED_KEY_RESOLVER_UPSTREAM_ENV=$(echo "$FED_ROUTE" | jq -r '.plugins["key-resolver"].upstream_key_env')
assert_eq "relay-opencode-federated: key-resolver upstream_key_env is OPENCODE_API_KEY" "OPENCODE_API_KEY" "$FED_KEY_RESOLVER_UPSTREAM_ENV"

FED_HAS_GATEWAY_AUTH=$(echo "$FED_ROUTE" | jq '.plugins | has("gateway-auth")')
assert_eq "relay-opencode-federated: gateway-auth plugin removed" "false" "$FED_HAS_GATEWAY_AUTH"

FED_HAS_SSE_USAGE=$(echo "$FED_ROUTE" | jq '.plugins | has("sse-usage")')
assert_eq "relay-opencode-federated: sse-usage plugin present" "true" "$FED_HAS_SSE_USAGE"

FED_HAS_AI_RATE=$(echo "$FED_ROUTE" | jq '.plugins | has("ai-rate-limiting")')
assert_eq "relay-opencode-federated: ai-rate-limiting plugin present" "true" "$FED_HAS_AI_RATE"

FED_HAS_PROMETHEUS=$(echo "$FED_ROUTE" | jq '.plugins | has("prometheus")')
assert_eq "relay-opencode-federated: prometheus plugin present" "true" "$FED_HAS_PROMETHEUS"

FED_HAS_HTTP_LOGGER=$(echo "$FED_ROUTE" | jq '.plugins | has("http-logger")')
assert_eq "relay-opencode-federated: http-logger plugin present" "true" "$FED_HAS_HTTP_LOGGER"

FED_HAS_PROXY_BUFFERING=$(echo "$FED_ROUTE" | jq '.plugins | has("proxy-buffering")')
assert_eq "relay-opencode-federated: proxy-buffering plugin present" "true" "$FED_HAS_PROXY_BUFFERING"

FED_HAS_REDACT=$(echo "$FED_ROUTE" | jq '.plugins | has("redact")')
assert_eq "relay-opencode-federated: redact plugin present" "true" "$FED_HAS_REDACT"

# --- shared assertions (http-logger on federated route) ---
HTTP_LOGGER_URI=$(echo "$FED_ROUTE" | jq -r '.plugins["http-logger"].uri')
assert_eq "http-logger uri is http://vector:8080/ingest" "http://vector:8080/ingest" "$HTTP_LOGGER_URI"

HAS_LOG_FORMAT=$(echo "$FED_ROUTE" | jq '.plugins["http-logger"] | has("log_format")')
assert_eq "http-logger has no log_format (uses default format)" "false" "$HAS_LOG_FORMAT"

INCLUDE_REQ_BODY=$(echo "$FED_ROUTE" | jq -r '.plugins["http-logger"].include_req_body')
assert_eq "http-logger include_req_body is true" "true" "$INCLUDE_REQ_BODY"

INCLUDE_RESP_BODY=$(echo "$FED_ROUTE" | jq -r '.plugins["http-logger"].include_resp_body')
assert_eq "http-logger include_resp_body is true" "true" "$INCLUDE_RESP_BODY"

MAX_REQ_BODY=$(echo "$FED_ROUTE" | jq -r '.plugins["http-logger"].max_req_body_bytes')
assert_eq "http-logger max_req_body_bytes is 8192" "8192" "$MAX_REQ_BODY"

MAX_RESP_BODY=$(echo "$FED_ROUTE" | jq -r '.plugins["http-logger"].max_resp_body_bytes')
assert_eq "http-logger max_resp_body_bytes is 8192" "8192" "$MAX_RESP_BODY"

# --- global assertions ---
HAS_KEY_AUTH=$(echo "$JSON_DATA" | jq '[.routes[] | .plugins | has("key-auth")] | any')
assert_eq "key-auth plugin removed from all routes" "false" "$HAS_KEY_AUTH"

NO_CONSUMERS=$(echo "$JSON_DATA" | jq 'has("consumers")')
assert_eq "No consumers section" "false" "$NO_CONSUMERS"

summary
