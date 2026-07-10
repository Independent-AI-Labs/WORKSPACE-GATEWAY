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
assert_eq "Exactly 3 routes" "3" "$ROUTE_COUNT"

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

OC_HAS_LIMIT_COUNT=$(echo "$OC_ROUTE" | jq '.plugins | has("limit-count")')
assert_eq "relay-opencode: limit-count plugin present" "true" "$OC_HAS_LIMIT_COUNT"

OC_HAS_PROMETHEUS=$(echo "$OC_ROUTE" | jq '.plugins | has("prometheus")')
assert_eq "relay-opencode: prometheus plugin present" "true" "$OC_HAS_PROMETHEUS"

OC_HAS_HTTP_LOGGER=$(echo "$OC_ROUTE" | jq '.plugins | has("http-logger")')
assert_eq "relay-opencode: http-logger plugin present" "true" "$OC_HAS_HTTP_LOGGER"

OC_HAS_REQUEST_ID_PLUGIN=$(echo "$OC_ROUTE" | jq '.plugins | has("request-id")')
assert_eq "relay-opencode: has request-id plugin" "true" "$OC_HAS_REQUEST_ID_PLUGIN"

OC_RID_HEADER=$(echo "$OC_ROUTE" | jq -r '.plugins["request-id"].header_name')
assert_eq "relay-opencode: request-id header_name is X-Request-Id" "X-Request-Id" "$OC_RID_HEADER"

# log_format must NOT be set: a custom log_format replaces APISIX's full
# default log fields, dropping client_ip/start_time/route_id/request/response.
OC_HAS_LOG_FORMAT=$(echo "$OC_ROUTE" | jq '.plugins["http-logger"] | has("log_format")')
assert_eq "relay-opencode: http-logger does NOT set log_format (uses full default)" "false" "$OC_HAS_LOG_FORMAT"

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

FED_HAS_LIMIT_COUNT=$(echo "$FED_ROUTE" | jq '.plugins | has("limit-count")')
assert_eq "relay-opencode-federated: limit-count plugin present" "true" "$FED_HAS_LIMIT_COUNT"

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

HAS_REQUEST_ID_PLUGIN=$(echo "$FED_ROUTE" | jq '.plugins | has("request-id")')
assert_eq "federated: has request-id plugin" "true" "$HAS_REQUEST_ID_PLUGIN"

FED_RID_HEADER=$(echo "$FED_ROUTE" | jq -r '.plugins["request-id"].header_name')
assert_eq "federated: request-id header_name is X-Request-Id" "X-Request-Id" "$FED_RID_HEADER"

# log_format must NOT be set: a custom log_format replaces APISIX's full
# default log fields, dropping client_ip/start_time/route_id/request/response.
HAS_LOG_FORMAT=$(echo "$FED_ROUTE" | jq '.plugins["http-logger"] | has("log_format")')
assert_eq "federated: http-logger does NOT set log_format (uses full default)" "false" "$HAS_LOG_FORMAT"

INCLUDE_REQ_BODY=$(echo "$FED_ROUTE" | jq -r '.plugins["http-logger"].include_req_body')
assert_eq "http-logger include_req_body is true" "true" "$INCLUDE_REQ_BODY"

INCLUDE_RESP_BODY=$(echo "$FED_ROUTE" | jq -r '.plugins["http-logger"].include_resp_body')
assert_eq "http-logger include_resp_body is true" "true" "$INCLUDE_RESP_BODY"

MAX_REQ_BODY=$(echo "$FED_ROUTE" | jq -r '.plugins["http-logger"].max_req_body_bytes')
assert_eq "http-logger max_req_body_bytes is 262144" "262144" "$MAX_REQ_BODY"

MAX_RESP_BODY=$(echo "$FED_ROUTE" | jq -r '.plugins["http-logger"].max_resp_body_bytes')
assert_eq "http-logger max_resp_body_bytes is 1048576" "1048576" "$MAX_RESP_BODY"

# --- global assertions ---
HAS_KEY_AUTH=$(echo "$JSON_DATA" | jq '[.routes[] | .plugins | has("key-auth")] | any')
assert_eq "key-auth plugin removed from all routes" "false" "$HAS_KEY_AUTH"

NO_CONSUMERS=$(echo "$JSON_DATA" | jq 'has("consumers")')
assert_eq "No consumers section" "false" "$NO_CONSUMERS"

# --- relay-llamafile (local no-auth LLM upstream, env-driven) ---
LF_ROUTE=$(echo "$JSON_DATA" | jq -c '[.routes[] | select(.id == "relay-llamafile")][0]')

LF_ID=$(echo "$LF_ROUTE" | jq -r '.id')
assert_eq "relay-llamafile: id is relay-llamafile" "relay-llamafile" "$LF_ID"

LF_URI=$(echo "$LF_ROUTE" | jq -r '.uri')
assert_eq "relay-llamafile: uri is /llamafile/*" "/llamafile/*" "$LF_URI"

LF_SCHEME=$(echo "$LF_ROUTE" | jq -r '.upstream.scheme')
assert_eq "relay-llamafile: upstream scheme is http" "http" "$LF_SCHEME"

LF_NODE=$(echo "$LF_ROUTE" | jq -r '.upstream.nodes | keys[0]')
assert_eq "relay-llamafile: upstream node is host.docker.internal:8765" "host.docker.internal:8765" "$LF_NODE"

LF_HAS_KEY_RESOLVER=$(echo "$LF_ROUTE" | jq '.plugins | has("key-resolver")')
assert_eq "relay-llamafile: no key-resolver (no-auth local)" "false" "$LF_HAS_KEY_RESOLVER"

LF_HAS_KEY_META=$(echo "$LF_ROUTE" | jq '.plugins | has("key-meta")')
assert_eq "relay-llamafile: no key-meta (no-auth local)" "false" "$LF_HAS_KEY_META"

LF_HAS_GATEWAY_AUTH=$(echo "$LF_ROUTE" | jq '.plugins | has("gateway-auth")')
assert_eq "relay-llamafile: gateway-auth plugin removed" "false" "$LF_HAS_GATEWAY_AUTH"

LF_HAS_PROXY_REWRITE=$(echo "$LF_ROUTE" | jq '.plugins | has("proxy-rewrite")')
assert_eq "relay-llamafile: proxy-rewrite plugin present" "true" "$LF_HAS_PROXY_REWRITE"

LF_REWRITE_REGEX=$(echo "$LF_ROUTE" | jq -r '.plugins["proxy-rewrite"].regex_uri[0]')
assert_eq "relay-llamafile: proxy-rewrite regex strips /llamafile/" "^/llamafile/(.*)" "$LF_REWRITE_REGEX"

LF_REWRITE_REPLACE=$(echo "$LF_ROUTE" | jq -r '.plugins["proxy-rewrite"].regex_uri[1]')
assert_eq "relay-llamafile: proxy-rewrite replacement strips prefix" '/$1' "$LF_REWRITE_REPLACE"

LF_HAS_SSE_USAGE=$(echo "$LF_ROUTE" | jq '.plugins | has("sse-usage")')
assert_eq "relay-llamafile: sse-usage plugin present" "true" "$LF_HAS_SSE_USAGE"

LF_SSE_CH_ADDR=$(echo "$LF_ROUTE" | jq -r '.plugins["sse-usage"].clickhouse_addr')
assert_eq "relay-llamafile: sse-usage clickhouse_addr is http://clickhouse:8123" "http://clickhouse:8123" "$LF_SSE_CH_ADDR"

LF_HAS_PROMETHEUS=$(echo "$LF_ROUTE" | jq '.plugins | has("prometheus")')
assert_eq "relay-llamafile: prometheus plugin present" "true" "$LF_HAS_PROMETHEUS"

LF_HAS_HTTP_LOGGER=$(echo "$LF_ROUTE" | jq '.plugins | has("http-logger")')
assert_eq "relay-llamafile: http-logger plugin present" "true" "$LF_HAS_HTTP_LOGGER"

LF_HAS_REQUEST_ID=$(echo "$LF_ROUTE" | jq '.plugins | has("request-id")')
assert_eq "relay-llamafile: request-id plugin present" "true" "$LF_HAS_REQUEST_ID"

LF_RID_HEADER=$(echo "$LF_ROUTE" | jq -r '.plugins["request-id"].header_name')
assert_eq "relay-llamafile: request-id header_name is X-Request-Id" "X-Request-Id" "$LF_RID_HEADER"

LF_HAS_PROXY_BUFFERING=$(echo "$LF_ROUTE" | jq '.plugins | has("proxy-buffering")')
assert_eq "relay-llamafile: proxy-buffering plugin present" "true" "$LF_HAS_PROXY_BUFFERING"

LF_HAS_REDACT=$(echo "$LF_ROUTE" | jq '.plugins | has("redact")')
assert_eq "relay-llamafile: redact plugin present" "true" "$LF_HAS_REDACT"

LF_HAS_LOG_FORMAT=$(echo "$LF_ROUTE" | jq '.plugins["http-logger"] | has("log_format")')
assert_eq "relay-llamafile: http-logger does NOT set log_format (uses full default)" "false" "$LF_HAS_LOG_FORMAT"

LF_HAS_LIMIT_COUNT=$(echo "$LF_ROUTE" | jq '.plugins | has("limit-count")')
assert_eq "relay-llamafile: limit-count plugin present" "true" "$LF_HAS_LIMIT_COUNT"

LF_LIMIT_KEY=$(echo "$LF_ROUTE" | jq -r '.plugins["limit-count"].key')
assert_eq "relay-llamafile: limit-count key is remote_addr (per IP)" "remote_addr" "$LF_LIMIT_KEY"

summary
