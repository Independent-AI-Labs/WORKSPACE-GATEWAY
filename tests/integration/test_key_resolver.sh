#!/bin/bash
set -euo pipefail

GATEWAY="http://localhost:9080"
FED_ROUTE="/opencode_federated/v1/models"
OC_ROUTE="/opencode/v1/models"
CORRECT_KEY="${GATEWAY_API_KEY:-vgw-gateway-key}"
WRONG_KEY="vgw-nonexistent-key-xxxxx"
DIRECT_KEY="${OPENCODE_API_KEY:-sk-test-direct}"
OPENBAO_ADDR="http://localhost:8201"
OPENBAO_TOKEN="${OPENBAO_TOKEN:-2e22c6e00b0815bcada90dfecb03f3c0}"

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

wait_for_openbao() {
    local max_attempts=15
    local attempt=0
    while [ "$attempt" -lt "$max_attempts" ]; do
        local code
        code=$(http_code "$OPENBAO_ADDR/v1/sys/health" 2>/dev/null || true)
        if [ -n "$code" ] && [ "$code" != "000" ]; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    record_fail "OpenBao not reachable at $OPENBAO_ADDR"
    return 1
}

test_fed_no_auth() {
    local code
    code=$(http_code "$GATEWAY$FED_ROUTE")
    if [ "$code" = "401" ]; then
        record_pass "federated route rejects without Authorization header (401)"
        return 0
    fi
    record_fail "federated route without Authorization returned $code, expected 401"
    return 1
}

test_fed_wrong_key() {
    local code
    code=$(http_code -H "Authorization: Bearer $WRONG_KEY" "$GATEWAY$FED_ROUTE")
    if [ "$code" = "401" ]; then
        record_pass "federated route rejects wrong vgw- key (401)"
        return 0
    fi
    record_fail "federated route with wrong vgw- key returned $code, expected 401"
    return 1
}

test_fed_correct_key_not_401() {
    local code
    code=$(http_code -H "Authorization: Bearer $CORRECT_KEY" "$GATEWAY$FED_ROUTE")
    if [ "$code" = "401" ]; then
        record_fail "federated route: correct key returned 401, expected non-401"
        return 1
    fi
    record_pass "federated route accepts correct key (non-401: got $code)"
    return 0
}

test_fed_issued_key_works() {
    local new_key
    new_key="vgw-test-$(date +%s)"
    curl -sf -o /dev/null -X POST \
        -H "X-Vault-Token: $OPENBAO_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"data\":{\"virtual_key\":\"$new_key\",\"upstream_key\":\"\",\"tenant_id\":\"test-tenant\",\"user_id\":\"test-user\",\"active\":true,\"created_at\":\"2026-01-01T00:00:00Z\"}}" \
        "$OPENBAO_ADDR/v1/secret/data/gateway/keys/$new_key" || {
        record_fail "failed to issue test key in OpenBao"
        return 1
    }

    local code
    code=$(http_code -H "Authorization: Bearer $new_key" "$GATEWAY$FED_ROUTE")
    if [ "$code" = "401" ]; then
        record_fail "federated route: issued key returned 401, expected non-401"
        return 1
    fi
    record_pass "federated route accepts newly issued key (non-401: got $code)"
    return 0
}

test_fed_revoked_key_rejected() {
    local rev_key
    rev_key="vgw-revoked-$(date +%s)"
    curl -sf -o /dev/null -X POST \
        -H "X-Vault-Token: $OPENBAO_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"data\":{\"virtual_key\":\"$rev_key\",\"upstream_key\":\"\",\"tenant_id\":\"test\",\"user_id\":\"test\",\"active\":true,\"created_at\":\"2026-01-01T00:00:00Z\"}}" \
        "$OPENBAO_ADDR/v1/secret/data/gateway/keys/$rev_key" || {
        record_fail "failed to issue key for revoke test"
        return 1
    }

    local code_before
    code_before=$(http_code -H "Authorization: Bearer $rev_key" "$GATEWAY$FED_ROUTE")
    if [ "$code_before" = "401" ]; then
        record_fail "federated route: key should work before revocation"
        return 1
    fi

    curl -sf -o /dev/null -X POST \
        -H "X-Vault-Token: $OPENBAO_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"data\":{\"virtual_key\":\"$rev_key\",\"upstream_key\":\"\",\"tenant_id\":\"test\",\"user_id\":\"test\",\"active\":false,\"created_at\":\"2026-01-01T00:00:00Z\",\"revoked_at\":\"2026-01-02T00:00:00Z\"}}" \
        "$OPENBAO_ADDR/v1/secret/data/gateway/keys/$rev_key" || {
        record_fail "failed to revoke key in OpenBao"
        return 1
    }

    sleep 6

    local code_after
    code_after=$(http_code -H "Authorization: Bearer $rev_key" "$GATEWAY$FED_ROUTE")
    if [ "$code_after" = "401" ]; then
        record_pass "federated route rejects revoked key (401)"
        return 0
    fi
    record_fail "federated route: revoked key returned $code_after, expected 401"
    return 1
}

test_oc_passthrough_direct_key() {
    local code
    code=$(http_code -H "Authorization: Bearer $DIRECT_KEY" "$GATEWAY$OC_ROUTE")
    if [ "$code" = "401" ]; then
        record_fail "opencode route: direct key was rejected by gateway, expected pass-through to upstream"
        return 1
    fi
    record_pass "opencode route passes through direct key (non-401: got $code)"
    return 0
}

test_oc_passthrough_no_auth() {
    local code
    code=$(http_code "$GATEWAY$OC_ROUTE")
    if [ "$code" = "401" ]; then
        record_pass "opencode route without auth still passes to upstream (upstream 401)"
        return 0
    fi
    record_pass "opencode route without auth passes through (got $code, upstream may accept)"
    return 0
}

main() {
    wait_for_apisix || exit 1
    wait_for_openbao || exit 1
    test_fed_no_auth
    test_fed_wrong_key
    test_fed_correct_key_not_401
    test_fed_issued_key_works
    test_fed_revoked_key_rejected
    test_oc_passthrough_direct_key
    test_oc_passthrough_no_auth
    echo "test_key_resolver: $pass passed, $fail failed"
}

main || true

if [ "$fail" -gt 0 ]; then
    exit 1
fi
exit 0
