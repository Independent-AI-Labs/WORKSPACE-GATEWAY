#!/bin/bash
set -euo pipefail

# Static auth-posture tests for etcd RBAC + APISIX etcd credentials
# (REQ-SECURITY-HARDENING FR-6).
_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
    _SELF="$SHG_SCRIPT_PATH"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass=0
fail=0

assert_eq() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "[PASS] $desc"
        pass=$((pass + 1))
    else
        echo "[FAIL] $desc -- expected: $expected, actual: $actual"
        fail=$((fail + 1))
    fi
}

summary() {
    echo ""
    echo "test_etcd_auth.sh: $pass passed, $fail failed"
    if [ "$fail" -gt 0 ]; then
        exit 1
    fi
}

INIT="$REPO_ROOT/res/scripts/etcd-auth-init.sh"
CONFIG="$REPO_ROOT/conf/config.yaml"

init_rc=0
INIT_BODY="$(cat "$INIT")" || init_rc=$?
assert_eq "etcd-auth-init.sh exists" "0" "$init_rc"

assert_eq "bootstrap creates root account" "1" \
    "$(printf '%s' "$INIT_BODY" | grep -c 'user add "root:')"
assert_eq "bootstrap creates apisix user" "1" \
    "$(printf '%s' "$INIT_BODY" | grep -c 'user add "apisix:')"
assert_eq "apisix role scoped to /apisix/ prefix" "1" \
    "$(printf '%s' "$INIT_BODY" | grep -c 'grant-permission apisix-route --prefix=true readwrite /apisix/')"
assert_eq "bootstrap is idempotent (auth-already-enabled path)" "1" \
    "$(printf '%s' "$INIT_BODY" | grep -c 'auth already enabled')"
assert_eq "bootstrap enables auth" "1" \
    "$(printf '%s' "$INIT_BODY" | grep -c 'ectl auth enable')"
assert_eq "no hardcoded etcd secret in the script" "0" \
    "$(printf '%s' "$INIT_BODY" | grep -cE 'PASSWORD=[A-Za-z0-9]{8,}')"

cfg_rc=0
CFG_BODY="$(cat "$CONFIG")" || cfg_rc=$?
assert_eq "config.yaml exists" "0" "$cfg_rc"

assert_eq "APISIX etcd username from env" "1" \
    "$(printf '%s' "$CFG_BODY" | grep -c 'username: ${{ETCD_GW_USER}}')"
assert_eq "APISIX etcd password from env" "1" \
    "$(printf '%s' "$CFG_BODY" | grep -c 'password: ${{ETCD_GW_PASSWORD}}')"
assert_eq "admin API not open to the world" "0" \
    "$(printf '%s' "$CFG_BODY" | grep -c '0.0.0.0/0')"
assert_eq "admin API restricted to loopback + stack IPs" "1" \
    "$(printf '%s' "$CFG_BODY" | grep -c '10.99.10.2/32')"
assert_eq "CH_APISIX_PASSWORD imported into nginx env" "1" \
    "$(printf '%s' "$CFG_BODY" | grep -c 'CH_APISIX_PASSWORD')"

summary
