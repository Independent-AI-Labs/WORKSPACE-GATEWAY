#!/bin/bash
set -euo pipefail

GATEWAY="http://localhost:9080"
CORRECT_KEY="opencode-gateway-key"
EXISTING_ROUTE="/zen/v1/models"
NONEXIST_ROUTE="/nonexistent"

pass=0
fail=0

record_pass() {
    echo "[PASS] $1"
    pass=$((pass + 1))
}

record_fail() {
    echo "[FAIL] $1"
    fail=$((fail + 1))
}

http_code() {
    curl -s -o /dev/null -w "%{http_code}" "$@" || true
}

wait_for_apisix() {
    local max_attempts=30
    local attempt=0
    while [ "$attempt" -lt "$max_attempts" ]; do
        local code
        code=$(http_code "$GATEWAY/" 2>/dev/null || true)
        if [ -n "$code" ] && [ "$code" != "000" ]; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    record_fail "APISIX not reachable at $GATEWAY"
    return 1
}

test_route_exists() {
    local code
    code=$(http_code -H "apikey: $CORRECT_KEY" "$GATEWAY$EXISTING_ROUTE")
    if [ "$code" = "404" ]; then
        record_fail "existing route $EXISTING_ROUTE returned 404"
        return 1
    fi
    record_pass "Route exists ($EXISTING_ROUTE returned $code, not 404)"
    return 0
}

test_nonexistent_route() {
    local code
    code=$(http_code -H "apikey: $CORRECT_KEY" "$GATEWAY$NONEXIST_ROUTE")
    if [ "$code" = "404" ]; then
        record_pass "Nonexistent route returned 404 as expected"
        return 0
    fi
    record_fail "nonexistent route $NONEXIST_ROUTE returned $code, expected 404"
    return 1
}

main() {
    wait_for_apisix || exit 1
    test_route_exists
    test_nonexistent_route
    echo "test_route_relay: $pass passed, $fail failed"
}

main || true

if [ "$fail" -gt 0 ]; then
    exit 1
fi
exit 0