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

HAS_REQ_BODY_PARSE=$(grep -c 'parse_regex' "$VECTOR_TOML" || true)
assert_eq "Remap uses parse_regex for model extraction" "true" "$([ "$HAS_REQ_BODY_PARSE" -ge 1 ] && echo true || echo false)"

HAS_TOKEN_EXTRACT=$(grep -c 'prompt_tokens' "$VECTOR_TOML" || true)
assert_eq "Remap extracts prompt_tokens" "1" "$HAS_TOKEN_EXTRACT"

HAS_KEY_ID=$(grep -c 'x-gateway-key-id' "$VECTOR_TOML" || true)
assert_eq "Remap extracts x-gateway-key-id header" "1" "$HAS_KEY_ID"

HAS_TENANT_ID=$(grep -c 'x-gateway-tenant-id' "$VECTOR_TOML" || true)
assert_eq "Remap extracts x-gateway-tenant-id header" "1" "$HAS_TENANT_ID"

HAS_SESSION_ID=$(grep -c 'x-session-id' "$VECTOR_TOML" || true)
assert_eq "Remap extracts x-session-id header" "1" "$HAS_SESSION_ID"

summary