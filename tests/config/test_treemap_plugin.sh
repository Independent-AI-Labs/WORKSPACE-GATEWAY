#!/bin/bash
set -euo pipefail

# Tests for the in-repo gateway-treemap Grafana panel plugin
# (res/grafana-plugins/gateway-treemap). Verifies the manifest, that the
# committed dist/ is what build.sh produces, and that the constraint/geometry
# and AMD-contract unit tests pass.

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
    _SELF="$SHG_SCRIPT_PATH"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN_DIR="$REPO_ROOT/res/grafana-plugins/gateway-treemap"

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
    echo "test_treemap_plugin.sh: $pass passed, $fail failed"
    if [ "$fail" -gt 0 ]; then
        exit 1
    fi
}

echo "=== Gateway Treemap Plugin Tests ==="
echo ""

[ -f "$PLUGIN_DIR/plugin.json" ] || { echo "[FAIL] missing plugin.json"; summary; }
[ -f "$PLUGIN_DIR/src/constraints.js" ] || { echo "[FAIL] missing src/constraints.js"; summary; }
[ -f "$PLUGIN_DIR/src/panel.js" ] || { echo "[FAIL] missing src/panel.js"; summary; }
[ -f "$PLUGIN_DIR/dist/module.js" ] || { echo "[FAIL] missing dist/module.js (run build.sh)"; summary; }

assert_eq "plugin.json declares type panel" "panel" "$(jq -r '.type' "$PLUGIN_DIR/plugin.json")"
assert_eq "plugin.json declares id gateway-treemap" "gateway-treemap" "$(jq -r '.id' "$PLUGIN_DIR/plugin.json")"
DIST_MANIFEST="false"
if [ -f "$PLUGIN_DIR/dist/plugin.json" ]; then
    DIST_MANIFEST="true"
fi
assert_eq "dist/plugin.json is committed" "true" "$DIST_MANIFEST"
MANIFEST_MATCH="false"
if cmp -s "$PLUGIN_DIR/plugin.json" "$PLUGIN_DIR/dist/plugin.json"; then
    MANIFEST_MATCH="true"
fi
assert_eq "dist/plugin.json matches the source manifest" "true" "$MANIFEST_MATCH"

# dist/ must be exactly what build.sh produces, so a stale bundle cannot ship.
TMP_OUT="$(mktemp -d)"
trap 'rm -rf "$TMP_OUT"' EXIT
BUILD_LOG="$TMP_OUT.build.log"
if GATEWAY_TREEMAP_DIR="$PLUGIN_DIR" bash "$PLUGIN_DIR/build.sh" "$TMP_OUT" >"$BUILD_LOG" 2>&1; then
    echo "[PASS] build.sh runs"
    pass=$((pass + 1))
else
    echo "[FAIL] build.sh failed:"
    cat "$BUILD_LOG"
    fail=$((fail + 1))
fi
DIFF_LOG="$TMP_OUT.diff.log"
if diff -r "$TMP_OUT" "$PLUGIN_DIR/dist" >"$DIFF_LOG" 2>&1; then
    echo "[PASS] committed dist/ matches build.sh output"
    pass=$((pass + 1))
else
    echo "[FAIL] dist/ is stale -- run: bash res/grafana-plugins/gateway-treemap/build.sh"
    cat "$DIFF_LOG"
    fail=$((fail + 1))
fi

if command -v node >"$TMP_OUT.which.log" 2>&1; then
    NODE_LOG="$TMP_OUT.node.log"
    if node --test "$PLUGIN_DIR/test/constraints.test.mjs" "$PLUGIN_DIR/test/plugin_smoke.test.mjs" >"$NODE_LOG" 2>&1; then
        echo "[PASS] node unit tests (constraints + AMD contract)"
        pass=$((pass + 1))
    else
        echo "[FAIL] node unit tests failed:"
        cat "$NODE_LOG"
        fail=$((fail + 1))
    fi
else
    echo "[FAIL] node not available -- cannot run the plugin unit tests"
    fail=$((fail + 1))
fi

summary
