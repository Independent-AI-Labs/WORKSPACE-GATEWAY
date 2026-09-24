#!/bin/bash
set -euo pipefail

# tests/scripts/test_gateway_key.sh
# Checks the unified key CLI surface (res/scripts/gateway-key.sh) without a
# running OpenBao: help, argument validation, and the Makefile dispatcher.

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
    _SELF="$SHG_SCRIPT_PATH"
fi
REPO_ROOT="$(cd "$(dirname "$_SELF")/../.." && pwd)"
CLI="$REPO_ROOT/res/scripts/gateway-key.sh"
TMP_OUT="$(mktemp)"
trap 'rm -f "$TMP_OUT"' EXIT

pass=0
fail=0

check() {
    local desc="$1"
    local code="$2"
    local expected="$3"
    if [ "$code" = "$expected" ]; then
        echo "[PASS] $desc"
        pass=$((pass + 1))
    else
        echo "[FAIL] $desc -- expected exit $expected, got $code"
        fail=$((fail + 1))
    fi
}

if [ -f "$CLI" ]; then CLI_EXISTS=yes; else CLI_EXISTS=no; fi
check "gateway-key.sh exists" "$CLI_EXISTS" "yes"

if [ -x "$CLI" ]; then CLI_EXEC=yes; else CLI_EXEC=no; fi
check "gateway-key.sh is executable" "$CLI_EXEC" "yes"

if "$CLI" help >"$TMP_OUT" 2>"$TMP_OUT"; then HELP_CODE=0; else HELP_CODE=$?; fi
check "help exits 0" "$HELP_CODE" "0"
if grep -qF 'gateway-key.sh' "$TMP_OUT"; then
    echo "[PASS] help prints usage"
    pass=$((pass + 1))
else
    echo "[FAIL] help omits usage text"
    fail=$((fail + 1))
fi

if "$CLI" bogus >"$TMP_OUT" 2>"$TMP_OUT"; then UNKNOWN_CODE=0; else UNKNOWN_CODE=$?; fi
if "$CLI" show >"$TMP_OUT" 2>"$TMP_OUT"; then SHOW_CODE=0; else SHOW_CODE=$?; fi
if "$CLI" map vgw-test >"$TMP_OUT" 2>"$TMP_OUT"; then MAP_CODE=0; else MAP_CODE=$?; fi
if "$CLI" revoke >"$TMP_OUT" 2>"$TMP_OUT"; then REVOKE_CODE=0; else REVOKE_CODE=$?; fi

check "unknown command fails" "$UNKNOWN_CODE" "1"
check "show without key id fails" "$SHOW_CODE" "1"
check "map without a mode fails" "$MAP_CODE" "1"
check "revoke without key id fails" "$REVOKE_CODE" "1"

if grep -qF 'gateway-key.sh' "$REPO_ROOT/Makefile"; then
    echo "[PASS] Makefile exposes the key dispatcher"
    pass=$((pass + 1))
else
    echo "[FAIL] Makefile does not invoke gateway-key.sh"
    fail=$((fail + 1))
fi

echo ""
echo "test_gateway_key.sh: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi
