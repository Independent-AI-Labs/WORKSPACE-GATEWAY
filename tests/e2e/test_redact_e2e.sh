#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    source "$REPO_ROOT/.env" || exit 1
    set +a
fi

GATEWAY_URL="http://localhost:9080"
PII_EMAIL="john.test.pi@example.com"
pass=0
fail=0

check() {
    local desc="$1"
    local result="$2"
    if [ "$result" = "0" ]; then
        echo "[PASS] $desc"
        pass=$((pass + 1))
    else
        echo "[FAIL] $desc"
        fail=$((fail + 1))
    fi
}

if [ -z "${OPENCODE_ZEN_API_KEY:-}" ]; then
    echo "[SKIP] OPENCODE_ZEN_API_KEY not set, skipping E2E redaction tests"
    exit 0
fi
if [ -z "${GATEWAY_API_KEY:-}" ]; then
    echo "[SKIP] GATEWAY_API_KEY not set, skipping E2E redaction tests"
    exit 0
fi

headers_file=$(mktemp)
body_file=$(mktemp)

http_code=$(curl -s -D "$headers_file" -o "$body_file" -w "%{http_code}" \
    --max-time 60 \
    -X POST "$GATEWAY_URL/zen/v1/chat/completions" \
    -H "apikey: $GATEWAY_API_KEY" \
    -H "Authorization: Bearer $OPENCODE_ZEN_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"big-pickle\",\"messages\":[{\"role\":\"user\",\"content\":\"My email is $PII_EMAIL, say hello in one word\"}],\"stream\":false}" || echo "000")

body=$(cat "$body_file")

if [ "$http_code" = "200" ]; then
    check "Redaction E2E request with PII returns 200" "0"
else
    echo "[DEBUG] http_code=$http_code body=$body"
    check "Redaction E2E request with PII returns 200 (got $http_code)" "1"
fi

redact_header=$(grep -i '^x-redact-active:' "$headers_file" 2>/dev/null | tr -d '\r' || echo "")
redact_value=$(printf '%s' "$redact_header" | tr -dc '0-9' || echo "")

if [ "$redact_value" = "1" ]; then
    check "Response contains X-Redact-Active: 1 header" "0"
else
    echo "[DEBUG] X-Redact-Active header was: '$redact_header'"
    check "Response contains X-Redact-Active: 1 header" "1"
fi

if grep -qi "$PII_EMAIL" "$body_file"; then
    echo "[DEBUG] response body contains original PII email"
    check "Response body does not contain original PII email" "1"
else
    check "Response body does not contain original PII email" "0"
fi

echo "[INFO] Waiting 5 seconds for Vector to process..."
sleep 5

CH_URL="http://localhost:8123"
PII_TOKEN="[EMAIL_1]"

echo "[INFO] Querying ClickHouse for logged request body..."
logged_req_body=$(curl -sf "$CH_URL/?query=SELECT+req_body+FROM+llm_gateway.request_log+ORDER+BY+timestamp+DESC+LIMIT+1+FORMAT+TabSeparated" 2>/dev/null || echo "")

if grep -q "$PII_TOKEN" <<< "$logged_req_body"; then
    check "ClickHouse logged request body contains redaction token" "0"
else
    check "ClickHouse logged request body contains redaction token" "1"
    echo "[DEBUG] logged_req_body does not contain $PII_TOKEN"
fi

if grep -qi "$PII_EMAIL" <<< "$logged_req_body"; then
    check "ClickHouse logged request body does NOT contain raw PII email" "1"
else
    check "ClickHouse logged request body does NOT contain raw PII email" "0"
fi

rm -f "$headers_file" "$body_file"

echo ""
echo "E2E redaction tests: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi