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
    echo "[SKIP] OPENCODE_ZEN_API_KEY not set, skipping E2E chat tests"
    exit 0
fi
if [ -z "${GATEWAY_API_KEY:-}" ]; then
    echo "[SKIP] GATEWAY_API_KEY not set, skipping E2E chat tests"
    exit 0
fi

send_chat() {
    local model="$1"
    local prompt="$2"
    local tmpfile
    tmpfile=$(mktemp)
    http_code=$(curl -s -o "$tmpfile" -w "%{http_code}" \
        --max-time 60 \
        -X POST "$GATEWAY_URL/zen/v1/chat/completions" \
        -H "apikey: $GATEWAY_API_KEY" \
        -H "Authorization: Bearer $OPENCODE_ZEN_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"$prompt\"}],\"stream\":false}" || echo "000")
    body=$(cat "$tmpfile")
    rm -f "$tmpfile"
    echo "$http_code"
    printf '%s' "$body" > /tmp/e2e_chat_body.json
}

# Test 1: Non-streaming chat with big-pickle
http_code=$(send_chat "big-pickle" "Say hello in one word")
body=$(cat /tmp/e2e_chat_body.json)
rm -f /tmp/e2e_chat_body.json

if [ "$http_code" = "200" ]; then
    content=$(printf '%s' "$body" | jq -r '.choices[0].message.content // empty' 2>/dev/null || echo "")
    if [ -n "$content" ]; then
        check "Non-streaming chat with big-pickle returns 200 with content" "0"
    else
        echo "[DEBUG] body was: $body"
        check "Non-streaming chat with big-pickle returns 200 with content" "1"
    fi
else
    echo "[DEBUG] http_code=$http_code body=$body"
    check "Non-streaming chat with big-pickle returns 200 with content (got $http_code)" "1"
fi

# Test 2: Different model (mimo-v2.5-free)
http_code=$(send_chat "mimo-v2.5-free" "Reply with the single word: ok")
body=$(cat /tmp/e2e_chat_body.json)
rm -f /tmp/e2e_chat_body.json

if [ "$http_code" = "200" ]; then
    content=$(printf '%s' "$body" | jq -r '.choices[0].message.content // empty' 2>/dev/null || echo "")
    if [ -n "$content" ]; then
        check "Chat with mimo-v2.5-free returns 200 with content" "0"
    else
        echo "[DEBUG] body was: $body"
        check "Chat with mimo-v2.5-free returns 200 with content" "1"
    fi
else
    echo "[DEBUG] http_code=$http_code body=$body"
    check "Chat with mimo-v2.5-free returns 200 with content (got $http_code)" "1"
fi

echo ""
echo "E2E chat tests: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi