#!/bin/bash
set -euo pipefail

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
    _SELF="$SHG_SCRIPT_PATH"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLIENT_SCRIPT="$REPO_ROOT/res/scripts/opencode-provider-login.sh"

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

assert_contains() {
    local desc="$1"
    local needle="$2"
    local haystack="$3"
    if echo "$haystack" | grep -qF -- "$needle"; then
        echo "[PASS] $desc"
        pass=$((pass + 1))
    else
        echo "[FAIL] $desc -- missing: $needle in: $haystack"
        fail=$((fail + 1))
    fi
}

summary() {
    echo ""
    echo "test_opencode_provider_login.sh: $pass passed, $fail failed"
    if [ "$fail" -gt 0 ]; then
        exit 1
    fi
}

# Sanity: script exists and is executable.
if [ ! -f "$CLIENT_SCRIPT" ]; then
    echo "[FAIL] client script not found: $CLIENT_SCRIPT"
    exit 1
fi
if [ ! -x "$CLIENT_SCRIPT" ]; then
    chmod +x "$CLIENT_SCRIPT" || { echo "[FAIL] cannot chmod client script"; exit 1; }
fi

# --- Test: --help works ---
HELP_OUTPUT=$(bash "$CLIENT_SCRIPT" --help 2>&1 || echo "")
assert_contains "help shows usage" "Usage:" "$HELP_OUTPUT"
assert_contains "help mentions provider-id" "--provider-id" "$HELP_OUTPUT"
assert_contains "help mentions --all" "--all" "$HELP_OUTPUT"
assert_contains "help mentions --require-auth" "--require-auth" "$HELP_OUTPUT"

# --- Test: missing --provider-id fails ---
MISSING_OUTPUT=$(bash "$CLIENT_SCRIPT" --gateway http://localhost:9080 2>&1 || echo "")
assert_contains "missing provider-id errors" "ERROR: --provider-id is required" "$MISSING_OUTPUT"

# --- Test: invalid gateway fails ---
INVALID_GATEWAY=$(bash "$CLIENT_SCRIPT" --provider-id test --gateway ftp://bad 2>&1 || echo "")
assert_contains "invalid gateway errors" "ERROR: --gateway must be an http(s) URL" "$INVALID_GATEWAY"

# --- Test: full OAuth flow with mock server ---
if ! command -v python3 1>&2; then
    echo "[SKIP] python3 not available; skipping live client script flow test"
    pass=$((pass + 1))
    summary
fi

TMPDIR="$(mktemp -d)"
chmod 755 "$TMPDIR"
trap 'rm -rf "$TMPDIR"' EXIT

PORT_FILE="$TMPDIR/port"
LOG_FILE="$TMPDIR/server.log"
CONFIG_FILE="$TMPDIR/opencode.json"
AUTH_FILE="$TMPDIR/auth.json"

python3 "$SCRIPT_DIR/mock_provider_server.py" "$PORT_FILE" "$LOG_FILE" >>"$LOG_FILE" 2>&1 &
SERVER_PID=$!

# Wait for port file to appear.
for _ in $(seq 1 30); do
    if [ -f "$PORT_FILE" ] && [ -s "$PORT_FILE" ]; then
        break
    fi
    sleep 0.1
done

if [ ! -f "$PORT_FILE" ] || [ ! -s "$PORT_FILE" ]; then
    echo "[FAIL] mock server did not start"
    if ! kill "$SERVER_PID"; then echo "[INFO] process $SERVER_PID already exited" >&2; fi
    fail=$((fail + 1))
    summary
fi

PORT=$(cat "$PORT_FILE")
GATEWAY="http://127.0.0.1:$PORT"

# Run client script in OAuth mode with --no-browser.
set +e
CLIENT_OUTPUT=$(timeout 30 bash "$CLIENT_SCRIPT" \
    --provider-id test-oauth \
    --require-auth \
    --gateway "$GATEWAY" \
    --session test-session \
    --config-file "$CONFIG_FILE" \
    --auth-file "$AUTH_FILE" \
    --no-browser \
    --no-clipboard \
    --device-timeout 5 2>&1)
CLIENT_RC=$?
set -e

if [ "$CLIENT_RC" -ne 0 ]; then
    echo "[FAIL] client script exited with status=$CLIENT_RC"
    echo "CLIENT_OUTPUT:"
    echo "$CLIENT_OUTPUT"
    echo "SERVER_LOG:"
    cat "$LOG_FILE" || echo "[INFO] no log file at $LOG_FILE"
    if ! kill "$SERVER_PID"; then echo "[INFO] process $SERVER_PID already exited" >&2; fi
    fail=$((fail + 1))
    summary
fi

assert_contains "client script reports login complete" "Login complete" "$CLIENT_OUTPUT"
assert_contains "client script registers the auth plugin" \
    "Auth plugin registered for test-oauth" "$CLIENT_OUTPUT"

# Plugin registration shape (FR-5.7): per-provider wrapper file with baked
# options under <config dir>/plugin, referenced as a plain string spec.
EXPECTED_WRAPPER="$(dirname "$CONFIG_FILE")/plugin/wg-auth-test-oauth.ts"
if [ -f "$EXPECTED_WRAPPER" ]; then
    assert_contains "wrapper imports the repo engine" \
        "res/opencode-plugin/workspace-gateway-auth.ts" "$(cat "$EXPECTED_WRAPPER")"
    assert_contains "wrapper bakes the provider id" \
        'provider: "test-oauth"' "$(cat "$EXPECTED_WRAPPER")"
    assert_contains "wrapper bakes the gateway url" \
        "gateway: \"$GATEWAY\"" "$(cat "$EXPECTED_WRAPPER")"
else
    echo "[FAIL] wrapper not created: $EXPECTED_WRAPPER"
    fail=$((fail + 1))
fi
if [ -f "$CONFIG_FILE" ]; then
    PLUGIN_HITS=$(jq --arg w "$EXPECTED_WRAPPER" \
        '[.plugin // [] | .[] | select(. == $w)] | length' "$CONFIG_FILE" || echo "0")
    assert_eq "plugin entry for test-oauth registered once" "1" "$PLUGIN_HITS"
fi

# Verify config file has the provider block.
if [ -f "$CONFIG_FILE" ]; then
    CONFIG_NAME=$(jq -r '.provider."test-oauth".name' "$CONFIG_FILE" || echo "__missing__")
    assert_eq "config file provider name" "Test OAuth" "$CONFIG_NAME"
    CONFIG_NPM=$(jq -r '.provider."test-oauth".npm' "$CONFIG_FILE" || echo "__missing__")
    assert_eq "config file provider npm" "test-oauth" "$CONFIG_NPM"
    assert_eq "config file baseURL" "http://gateway/test" "$(jq -r '.provider."test-oauth".options.baseURL' "$CONFIG_FILE" || echo "__missing__")"
else
    echo "[FAIL] config file not created: $CONFIG_FILE"
    fail=$((fail + 1))
fi

# Verify auth file has the token.
if [ -f "$AUTH_FILE" ]; then
    AUTH_KEY=$(jq -r '."test-oauth".key' "$AUTH_FILE" || echo "__missing__")
    AUTH_TYPE=$(jq -r '."test-oauth".type' "$AUTH_FILE" || echo "__missing__")
    assert_eq "auth file type" "api" "$AUTH_TYPE"
    assert_eq "auth file key" "test-access-token" "$AUTH_KEY"
    AUTH_PERMS=$(stat -c '%a' "$AUTH_FILE" || echo "__missing__")
    assert_eq "auth file permissions" "600" "$AUTH_PERMS"
else
    echo "[FAIL] auth file not created: $AUTH_FILE"
    fail=$((fail + 1))
fi

# Verify the neutral default User-Agent was sent on the opencode request
# (provider-specific UAs are the gateway's concern, not the client's).
if [ -f "$LOG_FILE" ]; then
    assert_contains "server saw neutral default User-Agent" \
        "UA=workspace-gateway-login/0.1" \
        "$(cat "$LOG_FILE")"
else
    echo "[FAIL] server log missing"
    fail=$((fail + 1))
fi

# --- Test: api_key provider with piped input (requires auth explicitly) ---
set +e
API_KEY_OUTPUT=$(echo "test-api-key-value" | timeout 30 bash "$CLIENT_SCRIPT" \
    --provider-id test-api-key \
    --require-auth \
    --gateway "$GATEWAY" \
    --session test-session-api \
    --config-file "$CONFIG_FILE" \
    --auth-file "$AUTH_FILE" \
    --no-browser 2>&1)
API_KEY_RC=$?
set -e

if [ "$API_KEY_RC" -ne 0 ]; then
    echo "[FAIL] api_key client script exited with status=$API_KEY_RC"
    echo "$API_KEY_OUTPUT"
    if ! kill "$SERVER_PID"; then echo "[INFO] process $SERVER_PID already exited" >&2; fi
    fail=$((fail + 1))
    summary
fi

if [ -f "$AUTH_FILE" ]; then
    assert_eq "api_key auth key" "test-api-key-value" \
        "$(jq -r '."test-api-key".key' "$AUTH_FILE" || echo "__missing__")"
else
    echo "[FAIL] auth file missing after api_key login"
    fail=$((fail + 1))
fi

# api_key providers get no plugin entry or wrapper, and the earlier
# test-oauth entry survives untouched (idempotent, per-provider registration).
if [ -f "$CONFIG_FILE" ]; then
    APIKEY_WRAPPER="$(dirname "$CONFIG_FILE")/plugin/wg-auth-test-api-key.ts"
    APIKEY_PLUGIN_HITS=$(jq --arg w "$APIKEY_WRAPPER" \
        '[.plugin // [] | .[] | select(. == $w)] | length' "$CONFIG_FILE" || echo "0")
    assert_eq "no plugin entry for api_key provider" "0" "$APIKEY_PLUGIN_HITS"
    if [ -f "$APIKEY_WRAPPER" ]; then
        echo "[FAIL] wrapper created for api_key provider: $APIKEY_WRAPPER"
        fail=$((fail + 1))
    else
        echo "[PASS] no wrapper for api_key provider"
        pass=$((pass + 1))
    fi
    OAUTH_WRAPPER="$(dirname "$CONFIG_FILE")/plugin/wg-auth-test-oauth.ts"
    OAUTH_PLUGIN_STILL=$(jq --arg w "$OAUTH_WRAPPER" \
        '[.plugin // [] | .[] | select(. == $w)] | length' "$CONFIG_FILE" || echo "0")
    assert_eq "test-oauth plugin entry preserved" "1" "$OAUTH_PLUGIN_STILL"
fi

# --- Test: browser-only OAuth provider is rejected with a pointer to the plugin ---
set +e
BROWSER_ONLY_OUTPUT=$(echo "" | timeout 30 bash "$CLIENT_SCRIPT" \
    --provider-id test-browser-only \
    --require-auth \
    --gateway "$GATEWAY" \
    --session test-session-browser \
    --config-file "$CONFIG_FILE" \
    --auth-file "$AUTH_FILE" \
    --no-browser \
    --no-clipboard 2>&1)
BROWSER_ONLY_RC=$?
set -e

if [ "$BROWSER_ONLY_RC" -eq 0 ]; then
    echo "[FAIL] browser-only provider should not complete a device login"
    fail=$((fail + 1))
else
    assert_contains "browser-only provider points to the opencode plugin" \
        "use the gateway OpenCode auth plugin for browser flows" \
        "$BROWSER_ONLY_OUTPUT"
fi

# --- Test: api_key provider skips auth by default (config-only install) ---
SKIP_CONFIG="$TMPDIR/opencode-skip.json"
SKIP_AUTH="$TMPDIR/auth-skip.json"
set +e
SKIP_OUTPUT=$(timeout 30 bash "$CLIENT_SCRIPT" \
    --provider-id test-api-key \
    --gateway "$GATEWAY" \
    --config-file "$SKIP_CONFIG" \
    --auth-file "$SKIP_AUTH" \
    --no-browser < /dev/null 2>&1)
SKIP_RC=$?
set -e

assert_eq "default api_key install exits 0" "0" "$SKIP_RC"
assert_contains "default api_key install reports skip" "Skipping API key" "$SKIP_OUTPUT"
if [ -f "$SKIP_CONFIG" ]; then
    SKIP_NAME=$(jq -r '.provider."test-api-key".name // "__missing__"' "$SKIP_CONFIG")
else
    SKIP_NAME="__missing__"
fi
assert_eq "default api_key install writes config" "Test API Key" "$SKIP_NAME"
if [ -f "$SKIP_AUTH" ]; then
    SKIP_KEY=$(jq -r '."test-api-key".key // "__missing__"' "$SKIP_AUTH")
else
    SKIP_KEY="__missing__"
fi
assert_eq "default api_key install writes NO auth entry" "__missing__" "$SKIP_KEY"

# --- Test: --all installs every provider (config-only by default) ---
ALL_CONFIG="$TMPDIR/opencode-all.json"
ALL_AUTH="$TMPDIR/auth-all.json"
set +e
ALL_OUTPUT=$(timeout 60 bash "$CLIENT_SCRIPT" \
    --all \
    --gateway "$GATEWAY" \
    --config-file "$ALL_CONFIG" \
    --auth-file "$ALL_AUTH" \
    --no-browser \
    --no-clipboard < /dev/null 2>&1)
ALL_RC=$?
set -e

assert_eq "--all exits 0" "0" "$ALL_RC"
assert_contains "--all installs oauth provider" "test-oauth" "$ALL_OUTPUT"
assert_contains "--all installs api-key provider" "test-api-key" "$ALL_OUTPUT"
assert_contains "--all reports completion" "All providers installed" "$ALL_OUTPUT"
if [ -f "$ALL_CONFIG" ]; then
    ALL_OAUTH_NAME=$(jq -r '.provider."test-oauth".name // "__missing__"' "$ALL_CONFIG")
    ALL_APIKEY_NAME=$(jq -r '.provider."test-api-key".name // "__missing__"' "$ALL_CONFIG")
else
    ALL_OAUTH_NAME="__missing__"
    ALL_APIKEY_NAME="__missing__"
fi
assert_eq "--all writes oauth provider config" "Test OAuth" "$ALL_OAUTH_NAME"
assert_eq "--all writes api-key provider config" "Test API Key" "$ALL_APIKEY_NAME"
if [ -f "$ALL_CONFIG" ]; then
    ALL_WRAPPER="$(dirname "$ALL_CONFIG")/plugin/wg-auth-test-oauth.ts"
    ALL_PLUGIN_HITS=$(jq --arg w "$ALL_WRAPPER" \
        '[.plugin // [] | .[] | select(. == $w)] | length' "$ALL_CONFIG" || echo "0")
    assert_eq "--all registers oauth plugin entry" "1" "$ALL_PLUGIN_HITS"
    ALL_APIKEY_WRAPPER="$(dirname "$ALL_CONFIG")/plugin/wg-auth-test-api-key.ts"
    ALL_APIKEY_PLUGIN_HITS=$(jq --arg w "$ALL_APIKEY_WRAPPER" \
        '[.plugin // [] | .[] | select(. == $w)] | length' "$ALL_CONFIG" || echo "0")
    assert_eq "--all registers no api_key plugin entry" "0" "$ALL_APIKEY_PLUGIN_HITS"
fi
if [ -f "$ALL_AUTH" ]; then
    ALL_AUTH_COUNT=$(jq 'length' "$ALL_AUTH")
else
    ALL_AUTH_COUNT=0
fi
assert_eq "--all writes NO auth entries by default" "0" "$ALL_AUTH_COUNT"

if ! kill "$SERVER_PID"; then echo "[INFO] process $SERVER_PID already exited" >&2; fi
if ! wait "$SERVER_PID"; then echo "[INFO] wait on $SERVER_PID returned $?" >&2; fi

summary
