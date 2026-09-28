#!/bin/bash
set -euo pipefail

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
    _SELF="$SHG_SCRIPT_PATH"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/res/scripts/opencode-anthropic-max.sh"

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

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF -- "$needle"; then
        echo "[PASS] $desc"
        pass=$((pass + 1))
    else
        echo "[FAIL] $desc -- missing: $needle"
        fail=$((fail + 1))
    fi
}

summary() {
    echo ""
    echo "test_opencode_anthropic_max.sh: $pass passed, $fail failed"
    if [ "$fail" -gt 0 ]; then
        exit 1
    fi
}

if [ ! -f "$SCRIPT" ]; then
    echo "[FAIL] installer not found: $SCRIPT"
    exit 1
fi

HELP_RC=0
HELP=$(bash "$SCRIPT" --help 2>&1) || HELP_RC=$?
assert_contains "help shows usage" "Usage:" "$HELP"
assert_contains "help mentions --gateway" "--gateway" "$HELP"
assert_contains "help mentions --plugin-version" "--plugin-version" "$HELP"

BAD_RC=0
BAD=$(bash "$SCRIPT" --plugin-version notsemver 2>&1) || BAD_RC=$?
assert_contains "invalid version errors" "ERROR: --plugin-version must be major.minor.patch" "$BAD"

BAD_GW_RC=0
BAD_GW=$(bash "$SCRIPT" --gateway ftp://bad 2>&1) || BAD_GW_RC=$?
assert_contains "invalid gateway errors" "ERROR: --gateway must be an http(s) URL" "$BAD_GW"

TMPDIR="$(mktemp -d)"
chmod 755 "$TMPDIR"
trap 'rm -rf "$TMPDIR"' EXIT

CONFIG="$TMPDIR/opencode.jsonc"
printf '{\n  // user config\n  "plugin": ["unrelated-plugin"],\n  "provider": { "other": {} }\n}\n' > "$CONFIG"

OUT=$(bash "$SCRIPT" --config-file "$CONFIG" --gateway http://localhost:9080 2>&1)
assert_contains "installer reports install" "Anthropic (Claude Pro/Max) installed." "$OUT"
assert_contains "installer prints base url" "export ANTHROPIC_BASE_URL=http://localhost:9080/anthropic" "$OUT"

ENTRY=$(jq -r '.plugin[] | select(startswith("@ex-machina/opencode-anthropic-auth"))' "$CONFIG")
assert_eq "plugin spec pinned" "@ex-machina/opencode-anthropic-auth@1.8.5" "$ENTRY"

UNRELATED=$(jq -r '.plugin[] | select(. == "unrelated-plugin")' "$CONFIG")
assert_eq "unrelated plugin preserved" "unrelated-plugin" "$UNRELATED"

ANTHROPIC_BLOCK=$(jq -r '.provider.anthropic // "__none__"' "$CONFIG")
assert_eq "installer does not define built-in anthropic provider" "__none__" "$ANTHROPIC_BLOCK"

COUNT=$(jq '[.plugin[] | select(startswith("@ex-machina/opencode-anthropic-auth"))] | length' "$CONFIG")
assert_eq "one plugin spec after first run" "1" "$COUNT"

SECOND=$(bash "$SCRIPT" --config-file "$CONFIG" 2>&1)
COUNT2=$(jq '[.plugin[] | select(startswith("@ex-machina/opencode-anthropic-auth"))] | length' "$CONFIG")
assert_eq "idempotent: one plugin spec after second run" "1" "$COUNT2"

PERMS=$(stat -c '%a' "$CONFIG")
assert_eq "config written 600" "600" "$PERMS"

# Single-file guard: a stale sibling must block the run.
GUARD="$TMPDIR/guard"
mkdir -p "$GUARD"
printf '{"provider":{}}\n' > "$GUARD/opencode.json"
GUARD_RC=0
GUARD_OUT=$(bash "$SCRIPT" --config-file "$GUARD/opencode.jsonc" 2>&1) || GUARD_RC=$?
if [ "$GUARD_RC" -ne 0 ]; then
    echo "[PASS] stale sibling refuses to run"
    pass=$((pass + 1))
else
    echo "[FAIL] stale sibling should refuse to run"
    fail=$((fail + 1))
fi
assert_contains "stale sibling names the conflict" "conflicting OpenCode config exists" "$GUARD_OUT"

summary
