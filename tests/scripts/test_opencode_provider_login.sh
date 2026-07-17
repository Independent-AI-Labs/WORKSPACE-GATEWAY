#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
HELP_OUTPUT=$(bash "$CLIENT_SCRIPT" --help 2>&1 || true)
assert_contains "help shows usage" "Usage:" "$HELP_OUTPUT"
assert_contains "help mentions provider-id" "--provider-id" "$HELP_OUTPUT"

# --- Test: missing --provider-id fails ---
MISSING_OUTPUT=$(bash "$CLIENT_SCRIPT" --gateway http://localhost:9080 2>&1 || true)
assert_contains "missing provider-id errors" "ERROR: --provider-id is required" "$MISSING_OUTPUT"

# --- Test: invalid gateway fails ---
INVALID_GATEWAY=$(bash "$CLIENT_SCRIPT" --provider-id test --gateway ftp://bad 2>&1 || true)
assert_contains "invalid gateway errors" "ERROR: --gateway must be an http(s) URL" "$INVALID_GATEWAY"

# --- Test: full OAuth flow with mock server ---
if ! command -v python3 >/dev/null 2>&1; then
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

python3 "$SCRIPT_DIR/mock_provider_server.py" "$PORT_FILE" "$LOG_FILE" >/dev/null 2>&1 &
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
    kill "$SERVER_PID" 2>/dev/null || true
    fail=$((fail + 1))
    summary
fi

PORT=$(cat "$PORT_FILE")
GATEWAY="http://127.0.0.1:$PORT"

# Run client script in OAuth mode with --no-browser.
set +e
CLIENT_OUTPUT=$(bash "$CLIENT_SCRIPT" \
    --provider-id test-oauth \
    --gateway "$GATEWAY" \
    --session test-session \
    --config-file "$CONFIG_FILE" \
    --auth-file "$AUTH_FILE" \
    --no-browser 2>&1)
CLIENT_RC=$?
set -e

if [ "$CLIENT_RC" -ne 0 ]; then
    echo "[FAIL] client script exited with rc=$CLIENT_RC"
    echo "CLIENT_OUTPUT:"
    echo "$CLIENT_OUTPUT"
    echo "SERVER_LOG:"
    cat "$LOG_FILE" 2>/dev/null || true
    kill "$SERVER_PID" 2>/dev/null || true
    fail=$((fail + 1))
    summary
fi

assert_contains "client script reports login complete" "Login complete" "$CLIENT_OUTPUT"

# Verify config file has the provider block.
if [ -f "$CONFIG_FILE" ]; then
    CONFIG_NAME=$(jq -r '.provider."test-oauth".name' "$CONFIG_FILE" 2>/dev/null || echo "__missing__")
    assert_eq "config file provider name" "Test OAuth" "$CONFIG_NAME"
    CONFIG_NPM=$(jq -r '.provider."test-oauth".npm' "$CONFIG_FILE" 2>/dev/null || echo "__missing__")
    assert_eq "config file provider npm" "test-oauth" "$CONFIG_NPM"
    assert_eq "config file baseURL" "http://gateway/test" "$(jq -r '.provider."test-oauth".options.baseURL' "$CONFIG_FILE" 2>/dev/null || echo "__missing__")"
else
    echo "[FAIL] config file not created: $CONFIG_FILE"
    fail=$((fail + 1))
fi

# Verify auth file has the token.
if [ -f "$AUTH_FILE" ]; then
    AUTH_KEY=$(jq -r '."test-oauth".key' "$AUTH_FILE" 2>/dev/null || echo "__missing__")
    AUTH_TYPE=$(jq -r '."test-oauth".type' "$AUTH_FILE" 2>/dev/null || echo "__missing__")
    assert_eq "auth file type" "api" "$AUTH_TYPE"
    assert_eq "auth file key" "test-access-token" "$AUTH_KEY"
    AUTH_PERMS=$(stat -c '%a' "$AUTH_FILE" 2>/dev/null || echo "__missing__")
    assert_eq "auth file permissions" "600" "$AUTH_PERMS"
else
    echo "[FAIL] auth file not created: $AUTH_FILE"
    fail=$((fail + 1))
fi

# Verify User-Agent was sent on the opencode request.
if [ -f "$LOG_FILE" ]; then
    assert_contains "server saw Kimi User-Agent" \
        "Kimi CLI (Linux 6.17.0-35-generic x64)" \
        "$(cat "$LOG_FILE")"
else
    echo "[FAIL] server log missing"
    fail=$((fail + 1))
fi

# --- Test: api_key provider with piped input ---
set +e
API_KEY_OUTPUT=$(echo "test-api-key-value" | bash "$CLIENT_SCRIPT" \
    --provider-id test-api-key \
    --gateway "$GATEWAY" \
    --session test-session-api \
    --config-file "$CONFIG_FILE" \
    --auth-file "$AUTH_FILE" \
    --no-browser 2>&1)
API_KEY_RC=$?
set -e

if [ "$API_KEY_RC" -ne 0 ]; then
    echo "[FAIL] api_key client script exited with rc=$API_KEY_RC"
    echo "$API_KEY_OUTPUT"
    kill "$SERVER_PID" 2>/dev/null || true
    fail=$((fail + 1))
    summary
fi

if [ -f "$AUTH_FILE" ]; then
    assert_eq "api_key auth key" "test-api-key-value" \
        "$(jq -r '."test-api-key".key' "$AUTH_FILE" 2>/dev/null || echo "__missing__")"
else
    echo "[FAIL] auth file missing after api_key login"
    fail=$((fail + 1))
fi

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true

summary
