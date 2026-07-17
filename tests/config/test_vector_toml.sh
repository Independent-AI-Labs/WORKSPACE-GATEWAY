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
    echo "test_vector_toml.sh: $pass passed, $fail failed"
    if [ "$fail" -gt 0 ]; then
        exit 1
    fi
}

VECTOR_TOML="$REPO_ROOT/conf/vector.toml"

HAS_HTTP_SERVER=$(grep -c 'type = "http_server"' "$VECTOR_TOML" || true)
assert_eq "Source type http_server" "1" "$HAS_HTTP_SERVER"

HAS_ADDRESS=$(grep -c 'address = "0.0.0.0:8080"' "$VECTOR_TOML" || true)
assert_eq "Address 0.0.0.0:8080" "1" "$HAS_ADDRESS"

HAS_PATH=$(grep -c 'path = "/ingest"' "$VECTOR_TOML" || true)
assert_eq "Path /ingest" "1" "$HAS_PATH"

HAS_CLICKHOUSE_SINK=$(grep -c 'type = "clickhouse"' "$VECTOR_TOML" || true)
assert_eq "Sink type clickhouse" "1" "$HAS_CLICKHOUSE_SINK"

HAS_ENDPOINT=$(grep -c 'http://clickhouse:8123' "$VECTOR_TOML" || true)
assert_eq "Endpoint http://clickhouse:8123" "1" "$HAS_ENDPOINT"

HAS_TABLE=$(grep -c 'table = "request_log"' "$VECTOR_TOML" || true)
assert_eq "Table request_log" "1" "$HAS_TABLE"

HAS_DATABASE=$(grep -c 'database = "llm_gateway"' "$VECTOR_TOML" || true)
assert_eq "Database is llm_gateway" "1" "$HAS_DATABASE"

HAS_SKIP_UNKNOWN=$(grep -c 'skip_unknown_fields = true' "$VECTOR_TOML" || true)
assert_eq "skip_unknown_fields is true" "1" "$HAS_SKIP_UNKNOWN"

HAS_REMAP=$(grep -c 'type = "remap"' "$VECTOR_TOML" || true)
assert_eq "Has remap transform" "1" "$HAS_REMAP"

HAS_REQ_BODY_PARSE=$(grep -c 'parse_json' "$VECTOR_TOML" || true)
assert_eq "Remap uses parse_json for model extraction" "true" "$([ "$HAS_REQ_BODY_PARSE" -ge 1 ] && echo true || echo false)"

HAS_TOKEN_EXTRACT=$(grep -c 'prompt_tokens' "$VECTOR_TOML" || true)
assert_eq "Remap extracts prompt_tokens" "1" "$HAS_TOKEN_EXTRACT"

HAS_KEY_ID=$(grep -c 'x-gateway-key-id' "$VECTOR_TOML" || true)
assert_eq "Remap extracts x-gateway-key-id header" "1" "$HAS_KEY_ID"

HAS_TENANT_ID=$(grep -c 'x-gateway-tenant-id' "$VECTOR_TOML" || true)
assert_eq "Remap extracts x-gateway-tenant-id header" "1" "$HAS_TENANT_ID"

HAS_SESSION_ID=$(grep -c 'x-session-id' "$VECTOR_TOML" || true)
assert_eq "Remap extracts x-session-id header" "1" "$HAS_SESSION_ID"

HAS_REQUEST_ID=$(grep -c 'request_id' "$VECTOR_TOML" || true)
assert_eq "Remap references request_id" "true" "$([ "$HAS_REQUEST_ID" -ge 1 ] && echo true || echo false)"

# request_id must be sourced from the X-Request-Id request header (set by
# the APISIX request-id plugin), since nginx's $request_id is not exposed
# to Vector except via the request header.
RID_FROM_HDR=$(grep -c '\.request_id = to_string!(get!(req_headers, \["x-request-id"\])' "$VECTOR_TOML" || true)
assert_eq "Remap extracts request_id from x-request-id request header" "true" "$([ "$RID_FROM_HDR" -ge 1 ] && echo true || echo false)"

# VRL must NOT read request_id from the legacy top-level logger field -
# the log_format override was removed (it dropped all default fields).
RID_LEGACY=$(grep -c '\.request_id = to_string!(\.request_id || "")' "$VECTOR_TOML" || true)
assert_eq "Remap does not read request_id from top-level logger field (regression guard)" "true" "$([ "$RID_LEGACY" -eq 0 ] && echo true || echo false)"

HAS_MODEL_NORM=$(grep -c 'downcase(model_raw)' "$VECTOR_TOML" || true)
assert_eq "Remap normalizes model to lowercase" "1" "$HAS_MODEL_NORM"

HAS_MODEL_SUFFIX=$(grep -c "parse_regex(model_lower" "$VECTOR_TOML" || true)
assert_eq "Remap strips provider prefix from model (generated block)" "1" "$HAS_MODEL_SUFFIX"

HAS_GEN_BEGIN=$(grep -c '# BEGIN GENERATED MODEL CANONICALIZATION' "$VECTOR_TOML" || true)
assert_eq "Remap model canonicalization is codegen-marked (BEGIN)" "1" "$HAS_GEN_BEGIN"

HAS_GEN_END=$(grep -c '# END GENERATED MODEL CANONICALIZATION' "$VECTOR_TOML" || true)
assert_eq "Remap model canonicalization is codegen-marked (END)" "1" "$HAS_GEN_END"

HAS_ALIAS_MAP=$(grep -c 'model_alias_map = {' "$VECTOR_TOML" || true)
assert_eq "Remap uses generated alias map" "1" "$HAS_ALIAS_MAP"

HAS_RETRY=$(grep -c 'retry_attempts' "$VECTOR_TOML" || true)
assert_eq "ClickHouse sink has retry_attempts" "1" "$HAS_RETRY"

HAS_BUFFER=$(grep -c 'when_full = "block"' "$VECTOR_TOML" || true)
assert_eq "ClickHouse sink has memory buffer block policy" "1" "$HAS_BUFFER"

HAS_BATCH=$(grep -c 'max_events = 50' "$VECTOR_TOML" || true)
assert_eq "ClickHouse sink has batch max_events=50" "1" "$HAS_BATCH"

# --- event_id / timestamp math (must match sse-usage.lua) ---
# APISIX http-logger sends `start_time` as integer MILLISECONDS since
# epoch. Vector must:
#   1. treat .start_time as ms directly (NOT multiply by 1000)
#   2. derive event_id from floor(ms / 1000) - integer seconds - so it
#      matches sse-usage.lua's math.floor(ngx.var.start_time) where
#      ngx start_time is epoch-seconds with ms precision.
ST_MS_RAW=$(grep -c 'start_time_ms = to_int(.start_time || 0) ?? 0' "$VECTOR_TOML" || true)
assert_eq "Remap reads .start_time as milliseconds directly (no *1000)" "1" "$ST_MS_RAW"

ST_DIV=$(grep -c 'start_time_int = to_int(start_time_ms / 1000)' "$VECTOR_TOML" || true)
assert_eq "Remap derives event_id seconds via start_time_ms / 1000" "1" "$ST_DIV"

# Regression guard: must NOT multiply .start_time by 1000 (it is already ms).
ST_BUG=$(grep -c 'start_time_f \* 1000' "$VECTOR_TOML" || true)
assert_eq "Remap does NOT multiply start_time by 1000 (regression guard)" "0" "$ST_BUG"

# timestamp uses from_unix_timestamp with "milliseconds" unit on start_time_ms.
ST_TS=$(grep -c 'from_unix_timestamp(start_time_ms, "milliseconds")' "$VECTOR_TOML" || true)
assert_eq "Remap builds timestamp from start_time_ms (milliseconds unit)" "1" "$ST_TS"

# Only ONE console/debug sink remains absent (single clickhouse sink).
SINK_COUNT=$(grep -c 'type = "clickhouse"' "$VECTOR_TOML" || true)
assert_eq "Single clickhouse sink (debug sink removed)" "1" "$SINK_COUNT"

summary