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
    echo "[SKIP] OPENCODE_ZEN_API_KEY not set, skipping E2E stream tests"
    exit 0
fi
if [ -z "${GATEWAY_API_KEY:-}" ]; then
    echo "[SKIP] GATEWAY_API_KEY not set, skipping E2E stream tests"
    exit 0
fi

headers_file=$(mktemp)
body_file=$(mktemp)

http_code=$(curl -s -D "$headers_file" -o "$body_file" -w "%{http_code}" \
    --max-time 90 \
    -X POST "$GATEWAY_URL/zen/v1/chat/completions" \
    -H "Authorization: Bearer $GATEWAY_API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"model":"big-pickle","messages":[{"role":"user","content":"Stream the words one two three"}],"stream":true}' || echo "000")

# Test 2: Streaming chat with big-pickle

if [ "$http_code" = "200" ]; then
    check "Streaming chat with big-pickle returns 200" "0"
else
    echo "[DEBUG] http_code=$http_code"
    body_debug=$(cat "$body_file" 2>/dev/null || echo "")
    echo "[DEBUG] body=$body_debug"
    check "Streaming chat with big-pickle returns 200 (got $http_code)" "1"
    rm -f "$headers_file" "$body_file"
    echo ""
    echo "E2E stream tests: $pass passed, $fail failed"
    if [ "$fail" -gt 0 ]; then
        exit 1
    fi
    exit 0
fi

content_type=$(grep -i '^content-type:' "$headers_file" 2>/dev/null | tr -d '\r' || echo "")

if grep -qi "text/event-stream" <<< "$content_type"; then
    check "Response Content-Type contains text/event-stream" "0"
else
    echo "[DEBUG] Content-Type was: '$content_type'"
    check "Response Content-Type contains text/event-stream" "1"
fi

sse_count=$(grep -c '^data:' "$body_file" 2>/dev/null || echo "0")
if [ "$sse_count" -gt 0 ]; then
    check "Response body contains SSE data events" "0"
else
    echo "[DEBUG] no SSE data lines found in body"
    check "Response body contains SSE data events" "1"
fi

rm -f "$headers_file" "$body_file"

echo ""
echo "E2E stream tests: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi