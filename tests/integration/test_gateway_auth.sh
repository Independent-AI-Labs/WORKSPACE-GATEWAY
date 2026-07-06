#!/bin/bash
set -euo pipefail

GATEWAY="http://localhost:9080"
ROUTE="/zen/v1/models"
CORRECT_KEY="opencode-gateway-key"
WRONG_KEY="this-key-is-wrong"

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

test_no_auth() {
    local code
    code=$(http_code "$GATEWAY$ROUTE")
    if [ "$code" = "401" ]; then
        record_pass "gateway-auth rejects without Authorization header (401)"
        return 0
    fi
    record_fail "gateway-auth without Authorization returned $code, expected 401"
    return 1
}

test_wrong_key() {
    local code
    code=$(http_code -H "Authorization: Bearer $WRONG_KEY" "$GATEWAY$ROUTE")
    if [ "$code" = "401" ]; then
        record_pass "gateway-auth rejects wrong key (401)"
        return 0
    fi
    record_fail "gateway-auth with wrong key returned $code, expected 401"
    return 1
}

test_correct_key_not_401() {
    local code
    code=$(http_code -H "Authorization: Bearer $CORRECT_KEY" "$GATEWAY$ROUTE")
    if [ "$code" = "401" ]; then
        record_fail "correct key returned 401, expected non-401"
        return 1
    fi
    record_pass "gateway-auth accepts correct key (non-401: got $code)"
    return 0
}

test_no_apikey_header_needed() {
    local code
    code=$(http_code -H "Authorization: Bearer $CORRECT_KEY" "$GATEWAY$ROUTE")
    if [ "$code" != "401" ]; then
        record_pass "inject mode works without apikey header ($code)"
        return 0
    fi
    record_fail "inject mode returned 401 without apikey header"
    return 1
}

main() {
    wait_for_apisix || exit 1
    test_no_auth
    test_wrong_key
    test_correct_key_not_401
    test_no_apikey_header_needed
    echo "test_gateway_auth: $pass passed, $fail failed"
}

main || true

if [ "$fail" -gt 0 ]; then
    exit 1
fi
exit 0
