#!/bin/bash
set -euo pipefail

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
  _SELF="$SHG_SCRIPT_PATH"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN="$REPO_ROOT/res/opencode-plugin/workspace-gateway-auth.ts"
OPENAI_EXAMPLE="$REPO_ROOT/res/opencode-workspace-gw-openai-device-oauth.example.json"
KIMI_EXAMPLE="$REPO_ROOT/res/opencode-workspace-gw-kimi-device-oauth.example.json"
OPENAI_PROVIDER="$REPO_ROOT/conf/providers/workspace-gw-openai-device-oauth.yaml"
LOGIN_SCRIPT="$REPO_ROOT/res/scripts/opencode-provider-login.sh"

pass=0
fail=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "[PASS] $desc"
    pass=$((pass + 1))
  else
    echo "[FAIL] $desc -- expected: $expected, actual: $actual"
    fail=$((fail + 1))
  fi
}

assert_eq "gateway auth plugin exists" "yes" "$([ -f "$PLUGIN" ] && printf yes || printf no)"
assert_eq "OpenAI example has one plugin entry" "1" "$(jq '.plugin | length' "$OPENAI_EXAMPLE")"
assert_eq "Kimi example has one plugin entry" "1" "$(jq '.plugin | length' "$KIMI_EXAMPLE")"
assert_eq "OpenAI example plugin provider" "workspace-gw-openai-device-oauth" \
  "$(jq -r '.plugin[0][1].provider' "$OPENAI_EXAMPLE")"
assert_eq "Kimi example plugin provider" "workspace-gw-kimi-device-oauth" \
  "$(jq -r '.plugin[0][1].provider' "$KIMI_EXAMPLE")"

if grep -q 'id: chatgpt-headless' "$OPENAI_PROVIDER" && \
   grep -q 'id: chatgpt-browser' "$OPENAI_PROVIDER" && \
   grep -q 'flow: device_authorization' "$OPENAI_PROVIDER" && \
   grep -q 'flow: authorization_code_pkce' "$OPENAI_PROVIDER"; then
  echo "[PASS] OpenAI provider advertises browser and device methods"
  pass=$((pass + 1))
else
  echo "[FAIL] OpenAI provider advertises browser and device methods"
  fail=$((fail + 1))
fi

if grep -q 'python3\|oauth-flow\|browser_oauth' "$LOGIN_SCRIPT"; then
  echo "[FAIL] legacy login script contains browser/interpreter implementation"
  fail=$((fail + 1))
else
  echo "[PASS] legacy login script has no browser/interpreter implementation"
  pass=$((pass + 1))
fi

echo "test_opencode_gateway_auth.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
