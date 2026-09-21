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
    echo "test_vector_toml.sh: $pass passed, $fail failed"
    if [ "$fail" -gt 0 ]; then
        exit 1
    fi
}

VECTOR_TOML="$REPO_ROOT/conf/vector.toml"

HAS_HTTP_SERVER_RC=0
HAS_HTTP_SERVER=$(grep -c 'type = "http_server"' "$VECTOR_TOML" ) || { HAS_HTTP_SERVER_RC=$?; HAS_HTTP_SERVER="0"; }
assert_eq "Source type http_server" "1" "$HAS_HTTP_SERVER"

HAS_ADDRESS_RC=0
HAS_ADDRESS=$(grep -c 'address = "0.0.0.0:8080"' "$VECTOR_TOML" ) || { HAS_ADDRESS_RC=$?; HAS_ADDRESS="0"; }
assert_eq "Address 0.0.0.0:8080" "1" "$HAS_ADDRESS"

HAS_PATH_RC=0
HAS_PATH=$(grep -c 'path = "/ingest"' "$VECTOR_TOML" ) || { HAS_PATH_RC=$?; HAS_PATH="0"; }
assert_eq "Path /ingest" "1" "$HAS_PATH"

HAS_CLICKHOUSE_SINK_RC=0
HAS_CLICKHOUSE_SINK=$(grep -c 'type = "clickhouse"' "$VECTOR_TOML" ) || { HAS_CLICKHOUSE_SINK_RC=$?; HAS_CLICKHOUSE_SINK="0"; }
assert_eq "Sink type clickhouse (metadata + bodies)" "2" "$HAS_CLICKHOUSE_SINK"

HAS_ENDPOINT_RC=0
HAS_ENDPOINT=$(grep -c 'http://clickhouse:8123' "$VECTOR_TOML" ) || { HAS_ENDPOINT_RC=$?; HAS_ENDPOINT="0"; }
assert_eq "Endpoint http://clickhouse:8123 (both sinks)" "2" "$HAS_ENDPOINT"

HAS_TABLE_RC=0
HAS_TABLE=$(grep -c 'table = "request_log"' "$VECTOR_TOML" ) || { HAS_TABLE_RC=$?; HAS_TABLE="0"; }
assert_eq "Table request_log" "1" "$HAS_TABLE"

HAS_DATABASE_RC=0
HAS_DATABASE=$(grep -c 'database = "llm_gateway"' "$VECTOR_TOML" ) || { HAS_DATABASE_RC=$?; HAS_DATABASE="0"; }
assert_eq "Database is llm_gateway (both sinks)" "2" "$HAS_DATABASE"

HAS_SKIP_UNKNOWN_RC=0
HAS_SKIP_UNKNOWN=$(grep -c 'skip_unknown_fields = true' "$VECTOR_TOML" ) || { HAS_SKIP_UNKNOWN_RC=$?; HAS_SKIP_UNKNOWN="0"; }
assert_eq "skip_unknown_fields is true (both sinks)" "2" "$HAS_SKIP_UNKNOWN"

HAS_REMAP_RC=0
HAS_REMAP=$(grep -c 'type = "remap"' "$VECTOR_TOML" ) || { HAS_REMAP_RC=$?; HAS_REMAP="0"; }
assert_eq "Has remap transform" "1" "$HAS_REMAP"

HAS_REQ_BODY_PARSE_RC=0
HAS_REQ_BODY_PARSE=$(grep -c 'parse_json' "$VECTOR_TOML" ) || { HAS_REQ_BODY_PARSE_RC=$?; HAS_REQ_BODY_PARSE="0"; }
assert_eq "Remap uses parse_json for model extraction" "true" "$(if [ "$HAS_REQ_BODY_PARSE" -ge 1 ]; then printf 'true'; else printf 'false'; fi)"

HAS_TOKEN_EXTRACT_RC=0
HAS_TOKEN_EXTRACT=$(grep -c 'prompt_tokens' "$VECTOR_TOML" ) || { HAS_TOKEN_EXTRACT_RC=$?; HAS_TOKEN_EXTRACT="0"; }
assert_eq "Remap extracts prompt_tokens" "1" "$HAS_TOKEN_EXTRACT"

HAS_KEY_ID_RC=0
HAS_KEY_ID=$(grep -c 'x-gateway-key-id' "$VECTOR_TOML" ) || { HAS_KEY_ID_RC=$?; HAS_KEY_ID="0"; }
assert_eq "Remap extracts x-gateway-key-id header" "1" "$HAS_KEY_ID"

HAS_TENANT_ID_RC=0
HAS_TENANT_ID=$(grep -c 'x-gateway-tenant-id' "$VECTOR_TOML" ) || { HAS_TENANT_ID_RC=$?; HAS_TENANT_ID="0"; }
assert_eq "Remap extracts x-gateway-tenant-id header" "1" "$HAS_TENANT_ID"

HAS_SESSION_ID_RC=0
HAS_SESSION_ID=$(grep -c 'x-session-id' "$VECTOR_TOML" ) || { HAS_SESSION_ID_RC=$?; HAS_SESSION_ID="0"; }
assert_eq "Remap extracts x-session-id header" "1" "$HAS_SESSION_ID"

HAS_REQUEST_ID_RC=0
HAS_REQUEST_ID=$(grep -c 'request_id' "$VECTOR_TOML" ) || { HAS_REQUEST_ID_RC=$?; HAS_REQUEST_ID="0"; }
assert_eq "Remap references request_id" "true" "$(if [ "$HAS_REQUEST_ID" -ge 1 ]; then printf 'true'; else printf 'false'; fi)"

# request_id must be sourced from the X-Request-Id request header (set by
# the APISIX request-id plugin), since nginx's $request_id is not exposed
# to Vector except via the request header.
RID_FROM_HDR_RC=0
RID_FROM_HDR=$(grep -c '\.request_id = to_string!(get!(req_headers, \["x-request-id"\])' "$VECTOR_TOML" ) || { RID_FROM_HDR_RC=$?; RID_FROM_HDR="0"; }
assert_eq "Remap extracts request_id from x-request-id request header" "true" "$(if [ "$RID_FROM_HDR" -ge 1 ]; then printf 'true'; else printf 'false'; fi)"

# VRL must NOT read request_id from the earlier top-level logger field -
# the log_format override was removed (it dropped all default fields).
RID_LEGACY_RC=0
RID_LEGACY=$(grep -c '\.request_id = to_string!(\.request_id || "")' "$VECTOR_TOML" ) || { RID_LEGACY_RC=$?; RID_LEGACY="0"; }
assert_eq "Remap does not read request_id from top-level logger field (regression guard)" "true" "$(if [ "$RID_LEGACY" -eq 0 ]; then printf 'true'; else printf 'false'; fi)"

HAS_MODEL_NORM_RC=0
HAS_MODEL_NORM=$(grep -c 'downcase(model_raw)' "$VECTOR_TOML" ) || { HAS_MODEL_NORM_RC=$?; HAS_MODEL_NORM="0"; }
assert_eq "Remap normalizes model to lowercase" "1" "$HAS_MODEL_NORM"

HAS_MODEL_SUFFIX_RC=0
HAS_MODEL_SUFFIX=$(grep -c "parse_regex(model_lower" "$VECTOR_TOML" ) || { HAS_MODEL_SUFFIX_RC=$?; HAS_MODEL_SUFFIX="0"; }
assert_eq "Remap strips provider prefix from model (generated block)" "1" "$HAS_MODEL_SUFFIX"

HAS_GEN_BEGIN_RC=0
HAS_GEN_BEGIN=$(grep -c '# BEGIN GENERATED MODEL CANONICALIZATION' "$VECTOR_TOML" ) || { HAS_GEN_BEGIN_RC=$?; HAS_GEN_BEGIN="0"; }
assert_eq "Remap model canonicalization is codegen-marked (BEGIN)" "1" "$HAS_GEN_BEGIN"

HAS_GEN_END_RC=0
HAS_GEN_END=$(grep -c '# END GENERATED MODEL CANONICALIZATION' "$VECTOR_TOML" ) || { HAS_GEN_END_RC=$?; HAS_GEN_END="0"; }
assert_eq "Remap model canonicalization is codegen-marked (END)" "1" "$HAS_GEN_END"

HAS_ALIAS_MAP_RC=0
HAS_ALIAS_MAP=$(grep -c 'model_alias_map = {' "$VECTOR_TOML" ) || { HAS_ALIAS_MAP_RC=$?; HAS_ALIAS_MAP="0"; }
assert_eq "Remap uses generated alias map" "1" "$HAS_ALIAS_MAP"

HAS_RETRY_RC=0
HAS_RETRY=$(grep -c 'retry_attempts' "$VECTOR_TOML" ) || { HAS_RETRY_RC=$?; HAS_RETRY="0"; }
assert_eq "ClickHouse sinks have retry_attempts (x2)" "2" "$HAS_RETRY"

HAS_BUFFER_RC=0
HAS_BUFFER=$(grep -c 'when_full = "block"' "$VECTOR_TOML" ) || { HAS_BUFFER_RC=$?; HAS_BUFFER="0"; }
assert_eq "ClickHouse sinks have memory buffer block policy (x2)" "2" "$HAS_BUFFER"

HAS_BATCH_RC=0
HAS_BATCH=$(grep -cx 'max_events = 1000' "$VECTOR_TOML" ) || { HAS_BATCH_RC=$?; HAS_BATCH="0"; }
assert_eq "ClickHouse sinks have batch max_events=1000 (x2)" "2" "$HAS_BATCH"

# --- event_id / timestamp math (must match sse-usage.lua) ---
# APISIX http-logger sends `start_time` as integer MILLISECONDS since
# epoch. Vector must:
#   1. treat .start_time as ms directly (NOT multiply by 1000)
#   2. derive event_id from floor(ms / 1000) - integer seconds - so it
#      matches sse-usage.lua's math.floor(ngx.var.start_time) where
#      ngx start_time is epoch-seconds with ms precision.
ST_MS_RAW_RC=0
ST_MS_RAW=$(grep -c 'start_time_ms = to_int(.start_time || 0) ?? 0' "$VECTOR_TOML" ) || { ST_MS_RAW_RC=$?; ST_MS_RAW="0"; }
assert_eq "Remap reads .start_time as milliseconds directly (no *1000)" "1" "$ST_MS_RAW"

ST_DIV_RC=0
ST_DIV=$(grep -c 'start_time_int = to_int(start_time_ms / 1000)' "$VECTOR_TOML" ) || { ST_DIV_RC=$?; ST_DIV="0"; }
assert_eq "Remap derives event_id seconds via start_time_ms / 1000" "1" "$ST_DIV"

# Regression guard: must NOT multiply .start_time by 1000 (it is already ms).
ST_BUG_RC=0
ST_BUG=$(grep -c 'start_time_f \* 1000' "$VECTOR_TOML" ) || { ST_BUG_RC=$?; ST_BUG="0"; }
assert_eq "Remap does NOT multiply start_time by 1000 (regression guard)" "0" "$ST_BUG"

# timestamp uses from_unix_timestamp with "milliseconds" unit on start_time_ms.
ST_TS_RC=0
ST_TS=$(grep -c 'from_unix_timestamp(start_time_ms, "milliseconds")' "$VECTOR_TOML" ) || { ST_TS_RC=$?; ST_TS="0"; }
assert_eq "Remap builds timestamp from start_time_ms (milliseconds unit)" "1" "$ST_TS"

# Bodies land in a dedicated request_bodies table (REQ-SECURITY-HARDENING
# FR-3); both sinks share the single remap output.
HAS_BODIES_TABLE_RC=0
HAS_BODIES_TABLE=$(grep -c 'table = "request_bodies"' "$VECTOR_TOML" ) || { HAS_BODIES_TABLE_RC=$?; HAS_BODIES_TABLE="0"; }
assert_eq "Bodies sink writes request_bodies" "1" "$HAS_BODIES_TABLE"

# Both sinks authenticate as vector_rw (basic auth; password from env).
HAS_SINK_AUTH_RC=0
HAS_SINK_AUTH=$(grep -c 'user = "vector_rw"' "$VECTOR_TOML" ) || { HAS_SINK_AUTH_RC=$?; HAS_SINK_AUTH="0"; }
assert_eq "Sinks authenticate as vector_rw (x2)" "2" "$HAS_SINK_AUTH"

HAS_SINK_AUTH_PW_RC=0
HAS_SINK_AUTH_PW=$(grep -c 'password = "${CH_VECTOR_PASSWORD}"' "$VECTOR_TOML" ) || { HAS_SINK_AUTH_PW_RC=$?; HAS_SINK_AUTH_PW="0"; }
assert_eq "Sink passwords come from CH_VECTOR_PASSWORD env (x2)" "2" "$HAS_SINK_AUTH_PW"

# Only ONE console/debug sink remains absent (two clickhouse sinks).
SINK_COUNT_RC=0
SINK_COUNT=$(grep -c 'type = "clickhouse"' "$VECTOR_TOML" ) || { SINK_COUNT_RC=$?; SINK_COUNT="0"; }
assert_eq "Exactly two clickhouse sinks (request_log + request_bodies)" "2" "$SINK_COUNT"

summary
