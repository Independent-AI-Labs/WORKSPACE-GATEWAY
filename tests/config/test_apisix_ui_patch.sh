#!/bin/bash
# test_apisix_ui_patch.sh: build-time Dashboard rebrand contract for
# res/scripts/patch-apisix-ui.sh (logo swap + title rewrite + fail-loud).
set -euo pipefail

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
    _SELF="$SHG_SCRIPT_PATH"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PATCHER="$REPO_ROOT/res/scripts/patch-apisix-ui.sh"
LOGO="$REPO_ROOT/res/docker/apisix-ui/workspace-ci-logo.svg"

pass=0
fail=0

ok()  { echo "[PASS] $1"; pass=$((pass + 1)); }
bad() { echo "[FAIL] $1"; fail=$((fail + 1)); }

assert_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 -- expected: $2, actual: $3"; fi
}
assert_has() {
    local content; content="$(<"$1")"
    if [[ "$content" == *"$2"* ]]; then ok "$3"; else bad "$3 -- missing: $2"; fi
}

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# Minimal stand-in for the image's /usr/local/apisix/ui bundle.
new_ui() {
    local d="$1"
    mkdir -p "$d/assets"
    printf '%s\n' '<!doctype html><html><head><title>Apache APISIX Dashboard</title></head></html>' > "$d/index.html"
    printf '%s\n' 'const Ac="Apache APISIX Dashboard";const i18n={dashboard:"APISIX Dashboard",logo:"APISIX Logo"};' > "$d/assets/index-abc123.js"
    printf '%s\n' '<svg>apisix</svg>' > "$d/assets/apisix-logo-abc123.svg"
}

# --- happy path ---
ui="$workdir/ui"
new_ui "$ui"
bash "$PATCHER" "$ui" "$LOGO"

assert_eq "logo asset content replaced" "$(<"$LOGO")" "$(<"$ui/assets/apisix-logo-abc123.svg")"
assert_has "$ui/index.html" "Workspace Gateway APISIX Dashboard" "index.html retitled"
assert_has "$ui/assets/index-abc123.js" 'Ac="Workspace Gateway APISIX Dashboard"' "document.title constant retitled"
assert_has "$ui/assets/index-abc123.js" 'dashboard:"Workspace Gateway APISIX Dashboard"' "i18n label retitled"

if [[ "$(<"$ui/index.html")" == *"Apache Workspace Gateway"* ]]; then
    bad "upstream 'Apache ' prefix collapsed"
else
    ok "upstream 'Apache ' prefix collapsed"
fi

# --- fail-loud: missing logo asset must abort the build ---
ui2="$workdir/ui2"
new_ui "$ui2"
rm "$ui2/assets/apisix-logo-abc123.svg"
if bash "$PATCHER" "$ui2" "$LOGO"; then
    bad "aborts when logo asset missing"
else
    ok "aborts when logo asset missing"
fi

# --- fail-loud: missing title text must abort the build ---
ui3="$workdir/ui3"
new_ui "$ui3"
printf '%s\n' 'no title here' > "$ui3/index.html"
printf '%s\n' 'const x=1;' > "$ui3/assets/index-abc123.js"
if bash "$PATCHER" "$ui3" "$LOGO"; then
    bad "aborts when title text missing"
else
    ok "aborts when title text missing"
fi

echo ""
echo "test_apisix_ui_patch.sh: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi
