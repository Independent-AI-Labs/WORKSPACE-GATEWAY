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
    echo "[SKIP] RUN_LIVE_API_TESTS not set, skipping cost E2E tests"
    exit 0
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

if [ -z "${OPENCODE_API_KEY:-}" ]; then
    echo "[SKIP] OPENCODE_API_KEY not set, skipping cost E2E tests"
    exit 0
fi

curl_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    "$GATEWAY_URL/" 2>/dev/null || echo "000")
if [ "$curl_code" = "000" ]; then
    echo "[SKIP] APISIX not reachable, skipping cost E2E tests"
    exit 0
fi

echo "[INFO] Sending chat request through gateway (opencode route)..."
http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 60 \
    -X POST "$GATEWAY_URL/opencode/v1/chat/completions" \
    -H "Authorization: Bearer $OPENCODE_API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"model":"glm-5.2","messages":[{"role":"user","content":"Say hello"}],"stream":false}' \
    2>/dev/null || echo "000")

if [ "$http_code" = "200" ]; then
    check "Chat request through gateway returned 200" "0"
else
    check "Chat request through gateway returned 200 (got $http_code)" "1"
fi

echo "[INFO] Waiting 3 seconds for usage_log insert..."
sleep 3

echo "[INFO] Querying usage_log for cost_source and cost..."
cost_data=$(curl -sf "$CH_URL/?query=SELECT+cost_source,cost+FROM+llm_gateway.usage_log+ORDER+BY+timestamp+DESC+LIMIT+1+FORMAT+TabSeparated" 2>/dev/null || echo "")

if [ -n "$cost_data" ]; then
    cost_source=$(echo "$cost_data" | cut -f1)
    cost_value=$(echo "$cost_data" | cut -f2)

    if [ "$cost_source" = "upstream" ] || [ "$cost_source" = "computed" ] || [ "$cost_source" = "unknown" ]; then
        check "usage_log cost_source is valid enum value ($cost_source)" "0"
    else
        check "usage_log cost_source is valid enum value (got '$cost_source')" "1"
    fi

    if [ "$cost_source" = "computed" ]; then
        if [ "${cost_value:-0}" != "0" ]; then
            check "usage_log cost > 0 for computed source (value=$cost_value)" "0"
        else
            check "usage_log cost > 0 for computed source (value=$cost_value)" "1"
        fi
    elif [ "$cost_source" = "upstream" ]; then
        if [ "${cost_value:-0}" != "0" ]; then
            check "usage_log cost > 0 for upstream source (value=$cost_value)" "0"
        else
            check "usage_log cost > 0 for upstream source (value=$cost_value)" "1"
        fi
    else
        check "usage_log cost_source is unknown (model not in models.dev)" "0"
    fi
else
    check "usage_log returned cost data" "1"
    check "usage_log cost_source is valid enum value" "1"
fi

echo ""
echo "Cost E2E tests: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi
