#!/bin/bash
set -euo pipefail

GATEWAY_URL="http://localhost:9080"
METRICS_URL="http://localhost:9100"

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

curl_code_RC=0
curl_code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 5 \
    "$GATEWAY_URL/" ) || { curl_code_RC=$?; curl_code="000"; }
if [ "$curl_code" = "000" ]; then
    echo "[SKIP] APISIX not reachable, skipping Prometheus tests"
    exit 0
fi

metrics_code_RC=0
metrics_code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 \
    "$METRICS_URL/apisix/prometheus/metrics" ) || { metrics_code_RC=$?; metrics_code="000"; }

if [ "$metrics_code" = "200" ]; then
    check "Prometheus metrics endpoint returns 200" "0"
else
    check "Prometheus metrics endpoint returns 200 (got $metrics_code)" "1"
fi

metrics_body_RC=0
metrics_body=$(curl -sS --max-time 10 \
    "$METRICS_URL/apisix/prometheus/metrics" ) || { metrics_body_RC=$?; metrics_body=""; }

if grep -q "apisix_" <<< "$metrics_body"; then
    check "Prometheus metrics body contains apisix_ metrics" "0"
else
    check "Prometheus metrics body contains apisix_ metrics" "1"
fi

if grep -q "apisix_http_requests_total\|apisix_nginx_http_current_connections\|apisix_node_info" <<< "$metrics_body"; then
    check "Prometheus has expected APISIX metric names" "0"
else
    check "Prometheus has expected APISIX metric names" "1"
fi

echo ""
echo "Prometheus tests: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi
