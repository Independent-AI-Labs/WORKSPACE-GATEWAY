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
assert_eq "Exactly 10 routes" "10" "$ROUTE_COUNT"

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

# --- relay-kimi (OAuth only to api.kimi.com) ---
KIMI_ROUTE=$(echo "$JSON_DATA" | jq -c '[.routes[] | select(.id == "relay-kimi")][0]')

KIMI_ID=$(echo "$KIMI_ROUTE" | jq -r '.id')
assert_eq "relay-kimi: id is relay-kimi" "relay-kimi" "$KIMI_ID"

KIMI_URI=$(echo "$KIMI_ROUTE" | jq -r '.uri')
assert_eq "relay-kimi: uri is /kimi/*" "/kimi/*" "$KIMI_URI"

KIMI_SCHEME=$(echo "$KIMI_ROUTE" | jq -r '.upstream.scheme')
assert_eq "relay-kimi: upstream scheme is https" "https" "$KIMI_SCHEME"

KIMI_NODE=$(echo "$KIMI_ROUTE" | jq -r '.upstream.nodes | keys[0]')
assert_eq "relay-kimi: upstream node is api.kimi.com:443" "api.kimi.com:443" "$KIMI_NODE"

KIMI_HAS_KIMI_AUTH=$(echo "$KIMI_ROUTE" | jq '.plugins | has("kimi-auth")')
assert_eq "relay-kimi: kimi-auth plugin present" "true" "$KIMI_HAS_KIMI_AUTH"

KIMI_HAS_PROXY_REWRITE=$(echo "$KIMI_ROUTE" | jq '.plugins | has("proxy-rewrite")')
assert_eq "relay-kimi: proxy-rewrite plugin present" "true" "$KIMI_HAS_PROXY_REWRITE"

KIMI_REWRITE_REGEX=$(echo "$KIMI_ROUTE" | jq -r '.plugins["proxy-rewrite"].regex_uri[0]')
assert_eq "relay-kimi: proxy-rewrite regex strips /kimi/" "^/kimi/(.*)" "$KIMI_REWRITE_REGEX"

KIMI_REWRITE_REPLACE=$(echo "$KIMI_ROUTE" | jq -r '.plugins["proxy-rewrite"].regex_uri[1]')
assert_eq "relay-kimi: proxy-rewrite replacement is /coding/v1/" '/coding/v1/$1' "$KIMI_REWRITE_REPLACE"

KIMI_HAS_KEY_META=$(echo "$KIMI_ROUTE" | jq '.plugins | has("key-meta")')
assert_eq "relay-kimi: key-meta plugin present" "true" "$KIMI_HAS_KEY_META"

KIMI_HAS_SSE_USAGE=$(echo "$KIMI_ROUTE" | jq '.plugins | has("sse-usage")')
assert_eq "relay-kimi: sse-usage plugin present" "true" "$KIMI_HAS_SSE_USAGE"

KIMI_HAS_LIMIT_COUNT=$(echo "$KIMI_ROUTE" | jq '.plugins | has("limit-count")')
assert_eq "relay-kimi: limit-count plugin present" "true" "$KIMI_HAS_LIMIT_COUNT"

KIMI_LIMIT_KEY=$(echo "$KIMI_ROUTE" | jq -r '.plugins["limit-count"].key')
assert_eq "relay-kimi: limit-count key is http_x_key_hash" "http_x_key_hash" "$KIMI_LIMIT_KEY"

KIMI_HAS_PROMETHEUS=$(echo "$KIMI_ROUTE" | jq '.plugins | has("prometheus")')
assert_eq "relay-kimi: prometheus plugin present" "true" "$KIMI_HAS_PROMETHEUS"

KIMI_HAS_HTTP_LOGGER=$(echo "$KIMI_ROUTE" | jq '.plugins | has("http-logger")')
assert_eq "relay-kimi: http-logger plugin present" "true" "$KIMI_HAS_HTTP_LOGGER"

KIMI_HAS_REQUEST_ID=$(echo "$KIMI_ROUTE" | jq '.plugins | has("request-id")')
assert_eq "relay-kimi: request-id plugin present" "true" "$KIMI_HAS_REQUEST_ID"

KIMI_HAS_PROXY_BUFFERING=$(echo "$KIMI_ROUTE" | jq '.plugins | has("proxy-buffering")')
assert_eq "relay-kimi: proxy-buffering plugin present" "true" "$KIMI_HAS_PROXY_BUFFERING"

KIMI_HAS_REDACT=$(echo "$KIMI_ROUTE" | jq '.plugins | has("redact")')
assert_eq "relay-kimi: redact plugin present" "true" "$KIMI_HAS_REDACT"

# --- relay-kimi-v1 (OpenAI-SDK-style /kimi/v1/* paths) ---
KIMI_V1_ROUTE=$(echo "$JSON_DATA" | jq -c '[.routes[] | select(.id == "relay-kimi-v1")][0]')

KIMI_V1_ID=$(echo "$KIMI_V1_ROUTE" | jq -r '.id')
assert_eq "relay-kimi-v1: id is relay-kimi-v1" "relay-kimi-v1" "$KIMI_V1_ID"

KIMI_V1_URI=$(echo "$KIMI_V1_ROUTE" | jq -r '.uri')
assert_eq "relay-kimi-v1: uri is /kimi/v1/*" "/kimi/v1/*" "$KIMI_V1_URI"

KIMI_V1_SCHEME=$(echo "$KIMI_V1_ROUTE" | jq -r '.upstream.scheme')
assert_eq "relay-kimi-v1: upstream scheme is https" "https" "$KIMI_V1_SCHEME"

KIMI_V1_NODE=$(echo "$KIMI_V1_ROUTE" | jq -r '.upstream.nodes | keys[0]')
assert_eq "relay-kimi-v1: upstream node is api.kimi.com:443" "api.kimi.com:443" "$KIMI_V1_NODE"

KIMI_V1_HAS_KIMI_AUTH=$(echo "$KIMI_V1_ROUTE" | jq '.plugins | has("kimi-auth")')
assert_eq "relay-kimi-v1: kimi-auth plugin present" "true" "$KIMI_V1_HAS_KIMI_AUTH"

KIMI_V1_HAS_PROXY_REWRITE=$(echo "$KIMI_V1_ROUTE" | jq '.plugins | has("proxy-rewrite")')
assert_eq "relay-kimi-v1: proxy-rewrite plugin present" "true" "$KIMI_V1_HAS_PROXY_REWRITE"

KIMI_V1_REWRITE_REGEX=$(echo "$KIMI_V1_ROUTE" | jq -r '.plugins["proxy-rewrite"].regex_uri[0]')
assert_eq "relay-kimi-v1: proxy-rewrite regex strips /kimi/v1/" "^/kimi/v1/(.*)" "$KIMI_V1_REWRITE_REGEX"

KIMI_V1_REWRITE_REPLACE=$(echo "$KIMI_V1_ROUTE" | jq -r '.plugins["proxy-rewrite"].regex_uri[1]')
assert_eq "relay-kimi-v1: proxy-rewrite replacement is /coding/v1/" '/coding/v1/$1' "$KIMI_V1_REWRITE_REPLACE"

KIMI_V1_HAS_KEY_META=$(echo "$KIMI_V1_ROUTE" | jq '.plugins | has("key-meta")')
assert_eq "relay-kimi-v1: key-meta plugin present" "true" "$KIMI_V1_HAS_KEY_META"

KIMI_V1_HAS_SSE_USAGE=$(echo "$KIMI_V1_ROUTE" | jq '.plugins | has("sse-usage")')
assert_eq "relay-kimi-v1: sse-usage plugin present" "true" "$KIMI_V1_HAS_SSE_USAGE"

KIMI_V1_HAS_LIMIT_COUNT=$(echo "$KIMI_V1_ROUTE" | jq '.plugins | has("limit-count")')
assert_eq "relay-kimi-v1: limit-count plugin present" "true" "$KIMI_V1_HAS_LIMIT_COUNT"

KIMI_V1_LIMIT_KEY=$(echo "$KIMI_V1_ROUTE" | jq -r '.plugins["limit-count"].key')
assert_eq "relay-kimi-v1: limit-count key is http_x_key_hash" "http_x_key_hash" "$KIMI_V1_LIMIT_KEY"

KIMI_V1_HAS_PROMETHEUS=$(echo "$KIMI_V1_ROUTE" | jq '.plugins | has("prometheus")')
assert_eq "relay-kimi-v1: prometheus plugin present" "true" "$KIMI_V1_HAS_PROMETHEUS"

KIMI_V1_HAS_HTTP_LOGGER=$(echo "$KIMI_V1_ROUTE" | jq '.plugins | has("http-logger")')
assert_eq "relay-kimi-v1: http-logger plugin present" "true" "$KIMI_V1_HAS_HTTP_LOGGER"

KIMI_V1_HAS_REQUEST_ID=$(echo "$KIMI_V1_ROUTE" | jq '.plugins | has("request-id")')
assert_eq "relay-kimi-v1: request-id plugin present" "true" "$KIMI_V1_HAS_REQUEST_ID"

KIMI_V1_HAS_PROXY_BUFFERING=$(echo "$KIMI_V1_ROUTE" | jq '.plugins | has("proxy-buffering")')
assert_eq "relay-kimi-v1: proxy-buffering plugin present" "true" "$KIMI_V1_HAS_PROXY_BUFFERING"

KIMI_V1_HAS_REDACT=$(echo "$KIMI_V1_ROUTE" | jq '.plugins | has("redact")')
assert_eq "relay-kimi-v1: redact plugin present" "true" "$KIMI_V1_HAS_REDACT"

# --- relay-kimi-federated (virtual-key API-key proxy to api.kimi.com) ---
KIMI_FED_ROUTE=$(echo "$JSON_DATA" | jq -c '[.routes[] | select(.id == "relay-kimi-federated")][0]')

KIMI_FED_ID=$(echo "$KIMI_FED_ROUTE" | jq -r '.id')
assert_eq "relay-kimi-federated: id is relay-kimi-federated" "relay-kimi-federated" "$KIMI_FED_ID"

KIMI_FED_URI=$(echo "$KIMI_FED_ROUTE" | jq -r '.uri')
assert_eq "relay-kimi-federated: uri is /kimi-federated/*" "/kimi-federated/*" "$KIMI_FED_URI"

KIMI_FED_NODE=$(echo "$KIMI_FED_ROUTE" | jq -r '.upstream.nodes | keys[0]')
assert_eq "relay-kimi-federated: upstream node is api.kimi.com:443" "api.kimi.com:443" "$KIMI_FED_NODE"

KIMI_FED_HAS_KEY_RESOLVER=$(echo "$KIMI_FED_ROUTE" | jq '.plugins | has("key-resolver")')
assert_eq "relay-kimi-federated: key-resolver plugin present" "true" "$KIMI_FED_HAS_KEY_RESOLVER"

KIMI_FED_KEY_RESOLVER_ENV=$(echo "$KIMI_FED_ROUTE" | jq -r '.plugins["key-resolver"].upstream_key_env')
assert_eq "relay-kimi-federated: key-resolver upstream_key_env is KIMI_API_KEY" "KIMI_API_KEY" "$KIMI_FED_KEY_RESOLVER_ENV"

KIMI_FED_KEY_RESOLVER_PREFIX=$(echo "$KIMI_FED_ROUTE" | jq -r '.plugins["key-resolver"].virtual_key_prefix')
assert_eq "relay-kimi-federated: key-resolver virtual_key_prefix is vgw-" "vgw-" "$KIMI_FED_KEY_RESOLVER_PREFIX"

KIMI_FED_HAS_KIMI_AUTH=$(echo "$KIMI_FED_ROUTE" | jq '.plugins | has("kimi-auth")')
assert_eq "relay-kimi-federated: no kimi-auth plugin (virtual-key, not OAuth)" "false" "$KIMI_FED_HAS_KIMI_AUTH"

KIMI_FED_REWRITE_REGEX=$(echo "$KIMI_FED_ROUTE" | jq -r '.plugins["proxy-rewrite"].regex_uri[0]')
assert_eq "relay-kimi-federated: proxy-rewrite regex strips /kimi-federated/" "^/kimi-federated/(.*)" "$KIMI_FED_REWRITE_REGEX"

KIMI_FED_REWRITE_REPLACE=$(echo "$KIMI_FED_ROUTE" | jq -r '.plugins["proxy-rewrite"].regex_uri[1]')
assert_eq "relay-kimi-federated: proxy-rewrite replacement is /coding/v1/" '/coding/v1/$1' "$KIMI_FED_REWRITE_REPLACE"

# --- relay-kimi-federated-v1 (OpenAI-SDK-style /kimi-federated/v1/* paths) ---
KIMI_FED_V1_ROUTE=$(echo "$JSON_DATA" | jq -c '[.routes[] | select(.id == "relay-kimi-federated-v1")][0]')

KIMI_FED_V1_ID=$(echo "$KIMI_FED_V1_ROUTE" | jq -r '.id')
assert_eq "relay-kimi-federated-v1: id is relay-kimi-federated-v1" "relay-kimi-federated-v1" "$KIMI_FED_V1_ID"

KIMI_FED_V1_URI=$(echo "$KIMI_FED_V1_ROUTE" | jq -r '.uri')
assert_eq "relay-kimi-federated-v1: uri is /kimi-federated/v1/*" "/kimi-federated/v1/*" "$KIMI_FED_V1_URI"

KIMI_FED_V1_HAS_KEY_RESOLVER=$(echo "$KIMI_FED_V1_ROUTE" | jq '.plugins | has("key-resolver")')
assert_eq "relay-kimi-federated-v1: key-resolver plugin present" "true" "$KIMI_FED_V1_HAS_KEY_RESOLVER"

KIMI_FED_V1_HAS_KIMI_AUTH=$(echo "$KIMI_FED_V1_ROUTE" | jq '.plugins | has("kimi-auth")')
assert_eq "relay-kimi-federated-v1: no kimi-auth plugin (virtual-key, not OAuth)" "false" "$KIMI_FED_V1_HAS_KIMI_AUTH"

KIMI_FED_V1_REWRITE_REGEX=$(echo "$KIMI_FED_V1_ROUTE" | jq -r '.plugins["proxy-rewrite"].regex_uri[0]')
assert_eq "relay-kimi-federated-v1: proxy-rewrite regex strips /kimi-federated/v1/" "^/kimi-federated/v1/(.*)" "$KIMI_FED_V1_REWRITE_REGEX"

KIMI_FED_V1_REWRITE_REPLACE=$(echo "$KIMI_FED_V1_ROUTE" | jq -r '.plugins["proxy-rewrite"].regex_uri[1]')
assert_eq "relay-kimi-federated-v1: proxy-rewrite replacement is /coding/v1/" '/coding/v1/$1' "$KIMI_FED_V1_REWRITE_REPLACE"

# --- relay-kimi-key (explicit API-key passthrough to api.kimi.com) ---
KIMI_KEY_ROUTE=$(echo "$JSON_DATA" | jq -c '[.routes[] | select(.id == "relay-kimi-key")][0]')

KIMI_KEY_ID=$(echo "$KIMI_KEY_ROUTE" | jq -r '.id')
assert_eq "relay-kimi-key: id is relay-kimi-key" "relay-kimi-key" "$KIMI_KEY_ID"

KIMI_KEY_URI=$(echo "$KIMI_KEY_ROUTE" | jq -r '.uri')
assert_eq "relay-kimi-key: uri is /kimi-key/*" "/kimi-key/*" "$KIMI_KEY_URI"

KIMI_KEY_NODE=$(echo "$KIMI_KEY_ROUTE" | jq -r '.upstream.nodes | keys[0]')
assert_eq "relay-kimi-key: upstream node is api.kimi.com:443" "api.kimi.com:443" "$KIMI_KEY_NODE"

KIMI_KEY_HAS_KIMI_AUTH=$(echo "$KIMI_KEY_ROUTE" | jq '.plugins | has("kimi-auth")')
assert_eq "relay-kimi-key: no kimi-auth plugin (passthrough)" "false" "$KIMI_KEY_HAS_KIMI_AUTH"

KIMI_KEY_REWRITE_REGEX=$(echo "$KIMI_KEY_ROUTE" | jq -r '.plugins["proxy-rewrite"].regex_uri[0]')
assert_eq "relay-kimi-key: proxy-rewrite regex strips /kimi-key/" "^/kimi-key/(.*)" "$KIMI_KEY_REWRITE_REGEX"

KIMI_KEY_REWRITE_REPLACE=$(echo "$KIMI_KEY_ROUTE" | jq -r '.plugins["proxy-rewrite"].regex_uri[1]')
assert_eq "relay-kimi-key: proxy-rewrite replacement is /coding/v1/" '/coding/v1/$1' "$KIMI_KEY_REWRITE_REPLACE"

# --- relay-kimi-key-v1 (OpenAI-SDK-style /kimi-key/v1/* paths) ---
KIMI_KEY_V1_ROUTE=$(echo "$JSON_DATA" | jq -c '[.routes[] | select(.id == "relay-kimi-key-v1")][0]')

KIMI_KEY_V1_ID=$(echo "$KIMI_KEY_V1_ROUTE" | jq -r '.id')
assert_eq "relay-kimi-key-v1: id is relay-kimi-key-v1" "relay-kimi-key-v1" "$KIMI_KEY_V1_ID"

KIMI_KEY_V1_URI=$(echo "$KIMI_KEY_V1_ROUTE" | jq -r '.uri')
assert_eq "relay-kimi-key-v1: uri is /kimi-key/v1/*" "/kimi-key/v1/*" "$KIMI_KEY_V1_URI"

KIMI_KEY_V1_HAS_KIMI_AUTH=$(echo "$KIMI_KEY_V1_ROUTE" | jq '.plugins | has("kimi-auth")')
assert_eq "relay-kimi-key-v1: no kimi-auth plugin (passthrough)" "false" "$KIMI_KEY_V1_HAS_KIMI_AUTH"

KIMI_KEY_V1_REWRITE_REGEX=$(echo "$KIMI_KEY_V1_ROUTE" | jq -r '.plugins["proxy-rewrite"].regex_uri[0]')
assert_eq "relay-kimi-key-v1: proxy-rewrite regex strips /kimi-key/v1/" "^/kimi-key/v1/(.*)" "$KIMI_KEY_V1_REWRITE_REGEX"

KIMI_KEY_V1_REWRITE_REPLACE=$(echo "$KIMI_KEY_V1_ROUTE" | jq -r '.plugins["proxy-rewrite"].regex_uri[1]')
assert_eq "relay-kimi-key-v1: proxy-rewrite replacement is /coding/v1/" '/coding/v1/$1' "$KIMI_KEY_V1_REWRITE_REPLACE"

# --- gateway-provider-sync (provider catalog and client config API) ---
PROVIDER_SYNC_ROUTE=$(echo "$JSON_DATA" | jq -c '[.routes[] | select(.id == "gateway-provider-sync")][0]')

PROVIDER_SYNC_ID=$(echo "$PROVIDER_SYNC_ROUTE" | jq -r '.id')
assert_eq "gateway-provider-sync: id is gateway-provider-sync" "gateway-provider-sync" "$PROVIDER_SYNC_ID"

PROVIDER_SYNC_URI=$(echo "$PROVIDER_SYNC_ROUTE" | jq -r '.uri')
assert_eq "gateway-provider-sync: uri is /gateway/providers*" "/gateway/providers*" "$PROVIDER_SYNC_URI"

PROVIDER_SYNC_HAS_PLUGIN=$(echo "$PROVIDER_SYNC_ROUTE" | jq '.plugins | has("provider-sync")')
assert_eq "gateway-provider-sync: provider-sync plugin present" "true" "$PROVIDER_SYNC_HAS_PLUGIN"

PROVIDER_SYNC_LIMIT_COUNT=$(echo "$PROVIDER_SYNC_ROUTE" | jq '.plugins["limit-count"].count')
assert_eq "gateway-provider-sync: limit-count count is 60" "60" "$PROVIDER_SYNC_LIMIT_COUNT"

PROVIDER_SYNC_LIMIT_WINDOW=$(echo "$PROVIDER_SYNC_ROUTE" | jq '.plugins["limit-count"].time_window')
assert_eq "gateway-provider-sync: limit-count time_window is 60" "60" "$PROVIDER_SYNC_LIMIT_WINDOW"

PROVIDER_SYNC_LIMIT_KEY=$(echo "$PROVIDER_SYNC_ROUTE" | jq -r '.plugins["limit-count"].key')
assert_eq "gateway-provider-sync: limit-count key is remote_addr" "remote_addr" "$PROVIDER_SYNC_LIMIT_KEY"

summary
