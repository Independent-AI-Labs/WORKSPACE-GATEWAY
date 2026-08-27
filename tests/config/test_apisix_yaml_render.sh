#!/bin/bash
set -euo pipefail

# tests/config/test_apisix_yaml_render.sh
# Drift guard: render conf/apisix.yaml.j2 with python jinja2 and assert the
# DEFAULT render substance-matches the committed conf/apisix.yaml, and that an
# env override actually changes the llamafile upstream node. Prevents the .j2
# source from diverging from the committed default render. Does NOT require a
# running stack.

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
    _SELF="$SHG_SCRIPT_PATH"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
J2_FILE="$REPO_ROOT/conf/apisix.yaml.j2"
COMMITTED="$REPO_ROOT/conf/apisix.yaml"

pass=0
fail=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "[PASS] $desc"
        pass=$((pass + 1))
    else
        echo "[FAIL] $desc -- expected: [$expected], actual: [$actual]"
        fail=$((fail + 1))
    fi
}

summary() {
    echo ""
    echo "test_apisix_yaml_render.sh: $pass passed, $fail failed"
    if [ "$fail" -gt 0 ]; then
        exit 1
    fi
}

assert_present() {
    local desc="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "[PASS] $desc"
        pass=$((pass + 1))
    else
        echo "[FAIL] $desc -- missing needle: [$needle]"
        fail=$((fail + 1))
    fi
}

assert_absent() {
    local desc="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "[FAIL] $desc -- unexpected needle present: [$needle]"
        fail=$((fail + 1))
    else
        echo "[PASS] $desc"
        pass=$((pass + 1))
    fi
}

# --- prerequisites ---
assert_eq "apisix.yaml.j2 template exists" "yes" "$([ -f "$J2_FILE" ] && echo yes || echo no)"
assert_eq "committed apisix.yaml exists" "yes" "$([ -f "$COMMITTED" ] && echo yes || echo no)"

# Verify python3 + jinja2 are available.
if ! python3 "$SCRIPT_DIR/check_jinja2.py"; then
    echo "[FAIL] python3 jinja2 module is importable"
    fail=$((fail + 1))
    summary
fi
assert_eq "python3 jinja2 available" "ok" "ok"

render_j2() {
    # $1 = LLAMAFILE_UPSTREAM_HOST, $2 = LLAMAFILE_UPSTREAM_PORT, $3 = output var name
    local host="$1" port="$2" outvar="$3"
    local rendered
    rendered=$(LLAMAFILE_UPSTREAM_HOST="$host" LLAMAFILE_UPSTREAM_PORT="$port" \
        python3 "$SCRIPT_DIR/render_apisix_j2.py" "$J2_FILE"
    )
    printf -v "$outvar" '%s' "$rendered"
}

# --- default render: empty host/port -> .j2 defaults bake in host.docker.internal:8765 ---
DEFAULT_RENDER=""
render_j2 "" "" DEFAULT_RENDER

assert_eq "default render: produced non-empty output" "yes" "$([ -n "$DEFAULT_RENDER" ] && echo yes || echo no)"

COMMITTED_TEXT="$(cat "$COMMITTED")"

# Substance match: route ids + llamafile node must match committed file.
DEFAULT_IDS="$(printf '%s' "$DEFAULT_RENDER" | grep -E 'id: relay' | sort | tr '\n' ',' )"
COMMITTED_IDS="$(printf '%s' "$COMMITTED_TEXT" | grep -E 'id: relay' | sort | tr '\n' ',')"
assert_eq "default render: route ids match committed" "$COMMITTED_IDS" "$DEFAULT_IDS"

DEFAULT_LF_NODE="$(printf '%s' "$DEFAULT_RENDER" | grep -E '"host.docker.internal:8765": 1' | tr -d ' ')"
COMMITTED_LF_NODE="$(printf '%s' "$COMMITTED_TEXT" | grep -E '"host.docker.internal:8765": 1' | tr -d ' ')"
assert_eq "default render: llamafile node line matches committed" "$COMMITTED_LF_NODE" "$DEFAULT_LF_NODE"

# Full text match (stripped trailing whitespace per-line) guards divergence.
DEFAULT_TRIM="$(printf '%s' "$DEFAULT_RENDER" | sed -e 's/[[:space:]]*$//' )"
COMMITTED_TRIM="$(printf '%s' "$COMMITTED_TEXT" | sed -e 's/[[:space:]]*$//' )"
assert_eq "default render: full text matches committed (no drift)" "$COMMITTED_TRIM" "$DEFAULT_TRIM"

# --- override render: custom host/port actually change the llamafile node ---
OVERRIDE_RENDER=""
render_j2 "192.168.1.50" "9999" OVERRIDE_RENDER

assert_eq "override render: produced non-empty output" "yes" "$([ -n "$OVERRIDE_RENDER" ] && echo yes || echo no)"

assert_present "override render: llamafile node uses custom host:port" "$OVERRIDE_RENDER" '"192.168.1.50:9999": 1'
assert_absent "override render: default node absent when overridden" "$OVERRIDE_RENDER" '"host.docker.internal:8765": 1'

# opencode nodes are NOT templated and must remain stable across renders.
# Three opencode routes share the opencode.ai:443 node, so the expected count is 3.
OC_PRESENT_OVERRIDE="$(printf '%s' "$OVERRIDE_RENDER" | grep -cF '"opencode.ai:443": 1' || echo "")"
assert_eq "override render: opencode.ai:443 node still present x3 (untouched)" "3" "$OC_PRESENT_OVERRIDE"

summary