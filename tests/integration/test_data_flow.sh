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
CH_URL="http://localhost:8123"

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

if [ -z "${GATEWAY_API_KEY:-}" ]; then
    echo "[SKIP] GATEWAY_API_KEY not set, skipping data flow tests"
    exit 0
fi

if [ -z "${OPENCODE_ZEN_API_KEY:-}" ]; then
    echo "[SKIP] OPENCODE_ZEN_API_KEY not set, skipping data flow tests"
    exit 0
fi

curl_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    "$GATEWAY_URL/" 2>/dev/null || echo "000")
if [ "$curl_code" = "000" ]; then
    echo "[SKIP] APISIX not reachable, skipping data flow tests"
    exit 0
fi

echo "[INFO] Sending chat request through gateway..."
http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 60 \
    -X POST "$GATEWAY_URL/zen/v1/chat/completions" \
    -H "apikey: $GATEWAY_API_KEY" \
    -H "Authorization: Bearer $OPENCODE_ZEN_API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"model":"big-pickle","messages":[{"role":"user","content":"Say hello in one word"}],"stream":false}' \
    2>/dev/null || echo "000")

if [ "$http_code" = "200" ]; then
    check "Chat request through gateway returned 200" "0"
else
    check "Chat request through gateway returned 200 (got $http_code)" "1"
fi

echo "[INFO] Waiting 5 seconds for Vector to process..."
sleep 5

echo "[INFO] Querying ClickHouse for request_log rows..."
row_count=$(curl -sf "$CH_URL/?query=SELECT+count()+FROM+llm_gateway.request_log" 2>/dev/null || echo "0")

if [ "$row_count" -gt 0 ] 2>/dev/null; then
    check "ClickHouse request_log has rows after request (count=$row_count)" "0"
else
    check "ClickHouse request_log has rows after request (count=$row_count)" "1"
fi

echo "[INFO] Querying for model-specific rows..."
model_count=$(curl -sf "$CH_URL/?query=SELECT+count()+FROM+llm_gateway.request_log+WHERE+model='big-pickle'" 2>/dev/null || echo "0")

if [ "$model_count" -gt 0 ] 2>/dev/null; then
    check "ClickHouse has big-pickle model rows (count=$model_count)" "0"
else
    check "ClickHouse has big-pickle model rows (count=$model_count)" "1"
fi

echo "[INFO] Querying for token usage..."
token_data=$(curl -sf "$CH_URL/?query=SELECT+prompt_tokens,completion_tokens,total_tokens+FROM+llm_gateway.request_log+WHERE+model='big-pickle'+ORDER+BY+timestamp+DESC+LIMIT+1+FORMAT+TabSeparated" 2>/dev/null || echo "")

if [ -n "$token_data" ]; then
    prompt_tokens=$(echo "$token_data" | cut -f1)
    total_tokens=$(echo "$token_data" | cut -f3)
    if [ "${prompt_tokens:-0}" -gt 0 ] 2>/dev/null; then
        check "ClickHouse has prompt_tokens > 0 (value=$prompt_tokens)" "0"
    else
        check "ClickHouse has prompt_tokens > 0 (value=$prompt_tokens)" "1"
    fi
    if [ "${total_tokens:-0}" -gt 0 ] 2>/dev/null; then
        check "ClickHouse has total_tokens > 0 (value=$total_tokens)" "0"
    else
        check "ClickHouse has total_tokens > 0 (value=$total_tokens)" "1"
    fi
else
    check "ClickHouse returned token usage data" "1"
    check "ClickHouse has prompt_tokens > 0" "1"
    check "ClickHouse has total_tokens > 0" "1"
fi

echo "[INFO] Querying for req_body..."
req_body=$(curl -sf "$CH_URL/?query=SELECT+req_body+FROM+llm_gateway.request_log+WHERE+model='big-pickle'+ORDER+BY+timestamp+DESC+LIMIT+1+FORMAT+TabSeparated" 2>/dev/null || echo "")

if [ -n "$req_body" ] && [ "$req_body" != "" ]; then
    check "ClickHouse has req_body populated" "0"
else
    check "ClickHouse has req_body populated" "1"
fi

echo ""
echo "Data flow tests: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi
