#!/bin/bash
set -euo pipefail

# test_provider_sync_client.sh
# Real end-to-end integration tests for the gateway-managed provider-sync
# service and the opencode-provider-login.sh client script.
#
# These tests exercise the ACTUAL running APISIX stack and real upstream
# endpoints (models.dev, Kimi OAuth, etc.). No mocks are used.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLIENT_SCRIPT="$REPO_ROOT/res/scripts/opencode-provider-login.sh"

GATEWAY="http://localhost:9080"

pass=0
fail=0

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

CONFIG_FILE="$TMPDIR/opencode.json"
AUTH_FILE="$TMPDIR/auth.json"

record_pass() {
    echo "[PASS] $1"
    pass=$((pass + 1))
}

record_fail() {
    echo "[FAIL] $1"
    fail=$((fail + 1))
}

assert_eq() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [ "$expected" = "$actual" ]; then
        record_pass "$desc"
    else
        record_fail "$desc -- expected: $expected, actual: $actual"
    fi
}

assert_contains() {
    local desc="$1"
    local needle="$2"
    local haystack="$3"
    if echo "$haystack" | grep -qF -- "$needle"; then
        record_pass "$desc"
    else
        record_fail "$desc -- missing: $needle in: $haystack"
    fi
}

assert_file_exists() {
    local desc="$1"
    local path="$2"
    if [ -f "$path" ]; then
        record_pass "$desc"
    else
        record_fail "$desc -- file not found: $path"
    fi
}

http_code() {
    curl -s -o /dev/null -w "%{http_code}" "$@" || true
}

http_json() {
    curl -sS --max-time 30 -H "Accept: application/json" "$@" || true
}

wait_for_apisix() {
    local max_attempts=30
    local attempt=0
    while [ "$attempt" -lt "$max_attempts" ]; do
        local code
        code=$(http_code "$GATEWAY/" 2>/dev/null || true)
        if [ -n "$code" ] && [ "$code" != "000" ]; then
            record_pass "APISIX reachable at $GATEWAY (HTTP $code)"
            return 0
        fi
        attempt=$((attempt + 1))
        echo "  [$attempt/$max_attempts] APISIX not reachable yet, retrying in 2s..."
        sleep 2
    done
    record_fail "APISIX not reachable at $GATEWAY after $max_attempts attempts"
    return 1
}

trigger_sync() {
    local max_attempts=5
    local attempt=0
    while [ "$attempt" -lt "$max_attempts" ]; do
        local resp
        local code
        code=$(http_code -X POST "$GATEWAY/gateway/providers/sync")
        if [ "$code" = "200" ] || [ "$code" = "202" ]; then
            record_pass "Provider sync triggered successfully (HTTP $code)"
            return 0
        fi
        attempt=$((attempt + 1))
        echo "  [$attempt/$max_attempts] sync returned HTTP $code, retrying in 2s..."
        sleep 2
    done
    record_fail "Provider sync failed after $max_attempts attempts"
    return 1
}

get_json_field() {
    local json="$1"
    local jq_expr="$2"
    echo "$json" | jq -r "$jq_expr" 2>/dev/null || echo "__missing__"
}

test_provider_list() {
    local resp
    resp=$(http_json "$GATEWAY/gateway/providers")
    assert_contains "provider list returns JSON array" "[" "$resp"
    local count
    count=$(get_json_field "$resp" 'length')
    if [ "$count" -ge 6 ] 2>/dev/null; then
        record_pass "provider list contains at least 6 providers (count=$count)"
    else
        record_fail "provider list expected >= 6 providers, got $count -- response: $resp"
    fi
}

test_provider_detail() {
    local provider_id="$1"
    local resp
    resp=$(http_json "$GATEWAY/gateway/providers/$provider_id")
    local returned_id
    returned_id=$(get_json_field "$resp" '.id // .id')
    if [ "$returned_id" = "$provider_id" ]; then
        record_pass "provider detail returns $provider_id"
    else
        record_fail "provider detail for $provider_id returned id=$returned_id -- response: $resp"
    fi
}

test_provider_opencode() {
    local provider_id="$1"
    local expected_name="$2"
    local resp
    resp=$(http_json "$GATEWAY/gateway/providers/$provider_id/opencode")
    local name
    name=$(get_json_field "$resp" '.provider.name')
    local auth_type
    auth_type=$(get_json_field "$resp" '.auth_type')
    if [ "$name" = "$expected_name" ]; then
        record_pass "opencode block for $provider_id has name '$expected_name'"
    else
        record_fail "opencode block for $provider_id expected name '$expected_name', got '$name' -- response: $resp"
    fi
}

run_client_login() {
    local provider_id="$1"
    shift
    bash "$CLIENT_SCRIPT" \
        --provider-id "$provider_id" \
        --gateway "$GATEWAY" \
        --session "test-session-$provider_id" \
        --config-file "$CONFIG_FILE" \
        --auth-file "$AUTH_FILE" \
        "$@" 2>&1
}

verify_provider_in_config() {
    local provider_id="$1"
    local expected_name="$2"
    local actual_name
    actual_name=$(jq -r ".provider.\"$provider_id\".name // \"__missing__\"" "$CONFIG_FILE" 2>/dev/null || echo "__missing__")
    assert_eq "config contains $provider_id with name '$expected_name'" "$expected_name" "$actual_name"
}

verify_provider_base_url() {
    local provider_id="$1"
    local expected_base_url="$2"
    local actual
    actual=$(jq -r ".provider.\"$provider_id\".options.baseURL // \"__missing__\"" "$CONFIG_FILE" 2>/dev/null || echo "__missing__")
    assert_eq "config $provider_id baseURL is '$expected_base_url'" "$expected_base_url" "$actual"
}

verify_auth_entry() {
    local provider_id="$1"
    local expected_key="$2"
    local actual_type
    local actual_key
    actual_type=$(jq -r ".\"$provider_id\".type // \"__missing__\"" "$AUTH_FILE" 2>/dev/null || echo "__missing__")
    actual_key=$(jq -r ".\"$provider_id\".key // \"__missing__\"" "$AUTH_FILE" 2>/dev/null || echo "__missing__")
    assert_eq "auth entry $provider_id type is 'api'" "api" "$actual_type"
    assert_eq "auth entry $provider_id key matches" "$expected_key" "$actual_key"
}

# --- Test: no-auth provider (llamafile) ---
test_client_no_auth_llamafile() {
    rm -f "$CONFIG_FILE" "$AUTH_FILE"
    local output
    set +e
    output=$(run_client_login workspace-gw-llamafile --no-browser 2>&1)
    local rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        record_fail "client login for llamafile failed (rc=$rc) -- output: $output"
        return 1
    fi
    assert_contains "llamafile client reports login complete" "Login complete" "$output"
    assert_file_exists "llamafile config file created" "$CONFIG_FILE"
    verify_provider_in_config workspace-gw-llamafile "Workspace GW (llamafile)"
    verify_provider_base_url workspace-gw-llamafile "$GATEWAY/llamafile/v1"
}

# --- Test: no-auth provider with models.dev enrichment (kimi own) ---
test_client_no_auth_kimi_own() {
    rm -f "$CONFIG_FILE" "$AUTH_FILE"
    local output
    set +e
    output=$(run_client_login workspace-gw-kimi-own --no-browser 2>&1)
    local rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        record_fail "client login for kimi-own failed (rc=$rc) -- output: $output"
        return 1
    fi
    assert_contains "kimi-own client reports login complete" "Login complete" "$output"
    verify_provider_in_config workspace-gw-kimi-own "Workspace GW (Kimi Own Key)"
    verify_provider_base_url workspace-gw-kimi-own "$GATEWAY/kimi-key"
    local model_count
    model_count=$(jq -r '.provider."workspace-gw-kimi-own".models | length' "$CONFIG_FILE" 2>/dev/null || echo "0")
    if [ "$model_count" -gt 0 ] 2>/dev/null; then
        record_pass "kimi-own config has enriched models (count=$model_count)"
    else
        record_fail "kimi-own config expected enriched models, got $model_count"
    fi
}

# --- Test: virtual_key provider with piped API key ---
test_client_virtual_key() {
    rm -f "$CONFIG_FILE" "$AUTH_FILE"
    local test_key="test-virtual-key-$(date +%s)"
    local output
    set +e
    output=$(echo "$test_key" | run_client_login workspace-gw-private --no-browser 2>&1)
    local rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        record_fail "client login for virtual_key failed (rc=$rc) -- output: $output"
        return 1
    fi
    assert_contains "virtual_key client reports login complete" "Login complete" "$output"
    verify_provider_in_config workspace-gw-private "Workspace GW (Virtual Key)"
    verify_provider_base_url workspace-gw-private "$GATEWAY/opencode_federated/v1"
    verify_auth_entry workspace-gw-private "$test_key"
    local perms
    perms=$(stat -c '%a' "$AUTH_FILE" 2>/dev/null || echo "__missing__")
    assert_eq "auth file permissions are 600" "600" "$perms"
}

# --- Test: config merge preserves existing providers ---
test_config_merge() {
    rm -f "$CONFIG_FILE" "$AUTH_FILE"
    cat > "$CONFIG_FILE" <<'EOF'
{
  "provider": {
    "existing-legacy": {
      "name": "Legacy Provider",
      "npm": "legacy",
      "options": { "baseURL": "http://legacy/v1" }
    }
  }
}
EOF
    local output
    set +e
    output=$(run_client_login workspace-gw-llamafile --no-browser 2>&1)
    local rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        record_fail "config merge login failed (rc=$rc) -- output: $output"
        return 1
    fi
    local existing_name
    existing_name=$(jq -r '.provider."existing-legacy".name // "__missing__"' "$CONFIG_FILE" 2>/dev/null || echo "__missing__")
    assert_eq "config merge preserves existing provider" "Legacy Provider" "$existing_name"
    verify_provider_in_config workspace-gw-llamafile "Workspace GW (llamafile)"
}

# --- Test: JSONC config input is handled ---
test_jsonc_config() {
    rm -f "$CONFIG_FILE" "$AUTH_FILE"
    cat > "$CONFIG_FILE" <<'EOF'
// OpenCode config with comments
{
  /* provider block */
  "provider": {}
}
EOF
    local output
    set +e
    output=$(run_client_login workspace-gw-llamafile --no-browser 2>&1)
    local rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        record_fail "JSONC config login failed (rc=$rc) -- output: $output"
        return 1
    fi
    if jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then
        record_pass "JSONC config was rewritten to valid JSON"
    else
        record_fail "JSONC config was not rewritten to valid JSON -- contents: $(cat "$CONFIG_FILE" 2>/dev/null || true)"
    fi
    verify_provider_in_config workspace-gw-llamafile "Workspace GW (llamafile)"
}

# --- Test: invalid provider id fails gracefully ---
test_invalid_provider() {
    rm -f "$CONFIG_FILE" "$AUTH_FILE"
    local output
    set +e
    output=$(run_client_login does-not-exist --no-browser 2>&1)
    local rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        record_fail "invalid provider login should have failed (rc=0) -- output: $output"
        return 1
    fi
    assert_contains "invalid provider reports error" "ERROR: gateway returned an invalid provider response" "$output"
}

# --- Test: OAuth device flow can be initiated with real upstream ---
test_oauth_device_flow_initiation() {
    local resp
    resp=$(http_json -X POST "$GATEWAY/gateway/providers/workspace-gw-kimi-oauth/opencode")
    local auth_type
    auth_type=$(get_json_field "$resp" '.auth_type')
    local auth_route
    auth_route=$(get_json_field "$resp" '.auth_route')
    assert_eq "oauth provider auth_type is 'oauth'" "oauth" "$auth_type"
    assert_eq "oauth provider auth_route is '/kimi/auth'" "/kimi/auth" "$auth_route"

    local device_resp
    device_resp=$(http_json -X POST "$GATEWAY/kimi/auth/device?session=test-session-$(date +%s)")
    local user_code
    user_code=$(get_json_field "$device_resp" '.user_code // empty')
    local device_code
    device_code=$(get_json_field "$device_resp" '.device_code // empty')
    if [ -n "$user_code" ] && [ -n "$device_code" ]; then
        record_pass "OAuth device flow initiated with real upstream (user_code present)"
    else
        record_fail "OAuth device flow did not return user_code/device_code -- response: $device_resp"
        return 1
    fi
}

# --- Test: OAuth client script times out cleanly when user does not authorize ---
test_oauth_client_timeout() {
    rm -f "$CONFIG_FILE" "$AUTH_FILE"
    local output
    set +e
    output=$(run_client_login workspace-gw-kimi-oauth --no-browser --device-timeout 5 2>&1)
    local rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        record_fail "oauth client should have timed out or failed (rc=0) -- output: $output"
        return 1
    fi
    assert_contains "oauth client reports polling" "Polling for authorization" "$output"
    if echo "$output" | grep -qF "expired" || echo "$output" | grep -qF "ERROR:"; then
        record_pass "oauth client exited with expected timeout/error"
    else
        record_fail "oauth client did not report expected timeout/error -- output: $output"
    fi
}

main() {
    echo "=== Provider Sync Client E2E Integration Tests ==="
    echo "  Gateway: $GATEWAY"
    echo "  Client:  $CLIENT_SCRIPT"
    echo ""

    wait_for_apisix || exit 1
    trigger_sync || exit 1

    test_provider_list
    test_provider_detail workspace-gw-llamafile
    test_provider_detail workspace-gw-kimi-oauth
    test_provider_detail workspace-gw-private
    test_provider_opencode workspace-gw-llamafile "Workspace GW (llamafile)"
    test_provider_opencode workspace-gw-kimi-oauth "Workspace GW (Kimi OAuth)"
    test_provider_opencode workspace-gw-private "Workspace GW (Virtual Key)"

    test_client_no_auth_llamafile
    test_client_no_auth_kimi_own
    test_client_virtual_key
    test_config_merge
    test_jsonc_config
    test_invalid_provider

    test_oauth_device_flow_initiation
    test_oauth_client_timeout

    echo ""
    echo "test_provider_sync_client: $pass passed, $fail failed"
}

main || true

if [ "$fail" -gt 0 ]; then
    exit 1
fi
exit 0
