#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    source "$REPO_ROOT/.env" || exit 1
    set +a
fi

if [ -z "${RUN_LIVE_API_TESTS:-}" ]; then
    echo "[SKIP] RUN_LIVE_API_TESTS not set, skipping live API streaming redaction tests"
    exit 0
fi

GATEWAY_URL="http://localhost:9080"
PII_EMAIL="stream.test.pi@example.com"

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

if [ -z "${OPENCODE_API_KEY:-}" ]; then
    echo "[SKIP] OPENCODE_API_KEY not set, skipping streaming redaction tests"
    exit 0
fi
if [ -z "${GATEWAY_API_KEY:-}" ]; then
    echo "[SKIP] GATEWAY_API_KEY not set, skipping streaming redaction tests"
    exit 0
fi

headers_file=$(mktemp)
body_file=$(mktemp)

http_code=$(curl -s -D "$headers_file" -o "$body_file" -w "%{http_code}" \
    --max-time 60 \
    -X POST "$GATEWAY_URL/opencode_federated/v1/chat/completions" \
    -H "Authorization: Bearer $GATEWAY_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"minimax-m3\",\"messages\":[{\"role\":\"user\",\"content\":\"My email is $PII_EMAIL, say hello in one word\"}],\"stream\":true}" || echo "000")

body=$(cat "$body_file")

if [ "$http_code" = "200" ]; then
    check "Streaming redaction request returns 200" "0"
else
    check "Streaming redaction request returns 200 (got $http_code)" "1"
fi

content_type=$(grep -i '^content-type:' "$headers_file" 2>/dev/null | tr -d '\r' || echo "")
if grep -qi "text/event-stream" <<< "$content_type"; then
    check "Streaming response Content-Type is text/event-stream" "0"
else
    check "Streaming response Content-Type is text/event-stream (got: $content_type)" "1"
fi

redact_header=$(grep -i '^x-redact-active:' "$headers_file" 2>/dev/null | tr -d '\r' || echo "")
redact_value=$(printf '%s' "$redact_header" | tr -dc '0-9' || echo "")
if [ "$redact_value" = "1" ]; then
    check "Streaming response has X-Redact-Active: 1 header" "0"
else
    check "Streaming response has X-Redact-Active: 1 header (got: $redact_header)" "1"
fi

if grep -q "^data:" "$body_file"; then
    check "Streaming response contains SSE data events" "0"
else
    check "Streaming response contains SSE data events" "1"
fi

if grep -q "\[EMAIL_1\]" "$body_file"; then
    check "Streaming response does NOT contain unredacted PII token" "1"
else
    check "Streaming response does NOT contain unredacted PII token" "0"
fi

rm -f "$headers_file" "$body_file"

echo ""
echo "E2E streaming redaction tests: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi
