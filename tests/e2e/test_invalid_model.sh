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
    echo "[SKIP] RUN_LIVE_API_TESTS not set, skipping live API invalid model tests"
    exit 0
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

if [ -z "${OPENCODE_API_KEY:-}" ]; then
    echo "[SKIP] OPENCODE_API_KEY not set, skipping invalid model tests"
    exit 0
fi
if [ -z "${GATEWAY_API_KEY:-}" ]; then
    echo "[SKIP] GATEWAY_API_KEY not set, skipping invalid model tests"
    exit 0
fi

body_file=$(mktemp)

http_code=$(curl -s -o "$body_file" -w "%{http_code}" --max-time 30 \
    -X POST "$GATEWAY_URL/opencode_federated/v1/chat/completions" \
    -H "Authorization: Bearer $GATEWAY_API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"model":"nonexistent-model-xyz-12345","messages":[{"role":"user","content":"hello"}],"stream":false}' \
    2>/dev/null || echo "000")

body=$(cat "$body_file")
rm -f "$body_file"

if [ "$http_code" = "000" ]; then
    check "Invalid model request returns non-zero HTTP code" "1"
elif [ "$http_code" -ge 400 ] 2>/dev/null; then
    check "Invalid model request returns 4xx/5xx error (got $http_code)" "0"
else
    check "Invalid model request returns 4xx/5xx error (got $http_code)" "1"
fi

if [ -n "$body" ] && grep -qi "error\|not found\|invalid" <<< "$body"; then
    check "Error response body contains error message" "0"
else
    check "Error response body contains error message" "1"
    echo "[DEBUG] body: $body"
fi

echo ""
echo "E2E invalid model tests: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi
