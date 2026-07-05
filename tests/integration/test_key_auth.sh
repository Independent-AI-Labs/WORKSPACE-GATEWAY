#!/bin/bash
set -euo pipefail

GATEWAY="http://localhost:9080"
ROUTE="/zen/v1/models"
CORRECT_KEY="opencode-gateway-key"
WRONG_KEY="this-key-is-wrong"
PATH_ROUTE="/nonexistent"

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

test_no_apikey() {
    local code
    code=$(http_code "$GATEWAY$ROUTE")
    if [ "$code" = "401" ]; then
        record_pass "key-auth rejects without apikey header (401)"
        return 0
    fi
    record_fail "key-auth without apikey returned $code, expected 401"
    return 1
}

test_wrong_apikey() {
    local code
    code=$(http_code -H "apikey: $WRONG_KEY" "$GATEWAY$ROUTE")
    if [ "$code" = "401" ]; then
        record_pass "key-auth rejects wrong key (401)"
        return 0
    fi
    record_fail "key-auth with wrong key returned $code, expected 401"
    return 1
}

test_correct_apikey_not_401() {
    local code
    code=$(http_code -H "apikey: $CORRECT_KEY" "$GATEWAY$ROUTE")
    if [ "$code" = "401" ]; then
        record_fail "correct key returned 401, expected non-401"
        return 1
    fi
    record_pass "key-auth accepts correct key (non-401: got $code)"
    return 0
}

main() {
    wait_for_apisix || exit 1
    test_no_apikey
    test_wrong_apikey
    test_correct_apikey_not_401
    echo "test_key_auth: $pass passed, $fail failed"
}

main || true

if [ "$fail" -gt 0 ]; then
    exit 1
fi
exit 0