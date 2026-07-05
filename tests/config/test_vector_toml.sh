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

summary