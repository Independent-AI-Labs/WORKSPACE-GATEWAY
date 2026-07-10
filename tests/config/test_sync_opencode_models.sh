#!/bin/bash
set -euo pipefail

# tests/config/test_sync_opencode_models.sh
# Persistent validation of the sync-opencode-models script pair (.sh + .lua).
# Asserts: both files exist, the shell script fetches llamafile models, the
# Lua script emits THREE provider entries (private, own, llamafile), the
# llamafile provider uses /llamafile/v1, has no apiKey, and the model entry
# has name=MiniCPM5 with context 128000. Also runs the Lua script inside the
# APISIX container with temp files to verify the output JSON structurally.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SYNC_SH="$REPO_ROOT/res/scripts/sync-opencode-models.sh"
SYNC_LUA="$REPO_ROOT/res/scripts/sync-opencode-models.lua"

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

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "[PASS] $desc"
        pass=$((pass + 1))
    else
        echo "[FAIL] $desc -- missing: [$needle]"
        fail=$((fail + 1))
    fi
}

# ── (A) File existence ──────────────────────────────────────────────────
assert_eq "sync-opencode-models.sh exists" "true" \
    "$([ -f "$SYNC_SH" ] && echo true || echo false)"
assert_eq "sync-opencode-models.lua exists" "true" \
    "$([ -f "$SYNC_LUA" ] && echo true || echo false)"

SH_BODY=""
LUA_BODY=""
[ -f "$SYNC_SH" ] && SH_BODY="$(cat "$SYNC_SH")"
[ -f "$SYNC_LUA" ] && LUA_BODY="$(cat "$SYNC_LUA")"

# ── (B) Shell script: llamafile fetch + arg passing ────────────────────
assert_contains "shell: fetches from /llamafile/v1/models" "$SH_BODY" '/llamafile/v1/models'
assert_contains "shell: creates LF_MODELS_FILE temp var" "$SH_BODY" 'LF_MODELS_FILE='
assert_contains "shell: passes llamafile_models.json to Lua" "$SH_BODY" '/sync-tmp/llamafile_models.json'
assert_contains "shell: mentions three providers in echo" "$SH_BODY" 'workspace-gw-llamafile'
assert_contains "shell: default fallback model id" "$SH_BODY" '/zip/MiniCPM5-1B-Q8_0.gguf'

# ── (C) Lua script: llamafile provider + model entry ────────────────────
assert_contains "lua: has build_llamafile_model_entry function" "$LUA_BODY" 'build_llamafile_model_entry'
assert_contains "lua: writes workspace-gw-llamafile provider" "$LUA_BODY" '"workspace-gw-llamafile"'
assert_contains "lua: llamafile provider name is Workspace GW (llamafile)" "$LUA_BODY" 'Workspace GW (llamafile)'
assert_contains "lua: llamafile provider uses /llamafile/v1 route" "$LUA_BODY" '/llamafile/v1'
assert_contains "lua: llamafile model name is MiniCPM5" "$LUA_BODY" '"MiniCPM5"'
assert_contains "lua: llamafile context limit is 128000" "$LUA_BODY" '128000'

# The llamafile provider must NOT have an apiKey field (no-auth route).
# Check that the llamafile provider block does not contain apiKey.
LUA_LF_BLOCK=$(printf '%s' "$LUA_BODY" | sed -n '/config\.provider\["workspace-gw-llamafile"\]/,/^}/p' || true)
assert_eq "lua: llamafile provider has no apiKey" "false" \
    "$([[ "$LUA_LF_BLOCK" == *"apiKey"* ]] && echo true || echo false)"

# ── (D) Functional test: run Lua inside APISIX container ─────────────────
# Creates temp files, runs the Lua script with them, and asserts the output
# JSON has three providers, the llamafile provider with the expected model.
if ! command -v podman >/dev/null 2>&1; then
    echo "[SKIP] podman not found, skipping functional Lua test"
else
    TMPDIR_FUNC="$(mktemp -d)"
    chmod 755 "$TMPDIR_FUNC"
    cleanup_func() {
        [ -n "$TMPDIR_FUNC" ] && [ -d "$TMPDIR_FUNC" ] && rm -rf "$TMPDIR_FUNC"
    }
    trap cleanup_func EXIT

    # Gateway models (dummy: one model)
    echo '["glm-5.2"]' > "$TMPDIR_FUNC/gateway_models.json"
    # models.dev (empty opencode section)
    echo '{"opencode":{"models":{}}}' > "$TMPDIR_FUNC/models_dev.json"
    # Llamafile models (default id)
    echo '["/zip/MiniCPM5-1B-Q8_0.gguf"]' > "$TMPDIR_FUNC/llamafile_models.json"
    # Empty opencode config
    echo '' > "$TMPDIR_FUNC/opencode_config.jsonc"

    LUA_JSON_FUNC=$(podman run --rm \
        -e 'LUA_PATH=/usr/local/apisix/deps/share/lua/5.1/?.lua;/usr/local/apisix/deps/share/lua/5.1/?/init.lua;;' \
        -e 'LUA_CPATH=/usr/local/apisix/deps/lib/lua/5.1/?.so;;' \
        -v "$TMPDIR_FUNC:/sync-tmp:ro" \
        -v "$SYNC_LUA:/sync.lua:ro" \
        --entrypoint /usr/local/openresty/luajit/bin/luajit \
        apache/apisix:3.17.0-debian \
        /sync.lua \
        /sync-tmp/opencode_config.jsonc \
        "http://localhost:9080" \
        "vgw-gateway-key" \
        /sync-tmp/gateway_models.json \
        /sync-tmp/models_dev.json \
        /sync-tmp/llamafile_models.json \
        "100" \
        "128000" \
        2>/dev/null) || {
        echo "[FAIL] functional: Lua script exited non-zero"
        fail=$((fail + 1))
        LUA_JSON_FUNC=""
    }

    if [ -n "$LUA_JSON_FUNC" ]; then
        # Verify three provider keys
        PROVIDER_COUNT=$(printf '%s' "$LUA_JSON_FUNC" | jq -r '.provider | keys | length' 2>/dev/null || echo "0")
        assert_eq "functional: three providers in output" "3" "$PROVIDER_COUNT"

        LF_NAME=$(printf '%s' "$LUA_JSON_FUNC" | jq -r '.provider["workspace-gw-llamafile"].name' 2>/dev/null || echo "")
        assert_eq "functional: llamafile provider name" "Workspace GW (llamafile)" "$LF_NAME"

        LF_API=$(printf '%s' "$LUA_JSON_FUNC" | jq -r '.provider["workspace-gw-llamafile"].api' 2>/dev/null || echo "")
        assert_eq "functional: llamafile provider api route" "http://localhost:9080/llamafile/v1" "$LF_API"

        LF_HAS_KEY=$(printf '%s' "$LUA_JSON_FUNC" | jq -r '.provider["workspace-gw-llamafile"].options.apiKey // "absent"' 2>/dev/null || echo "")
        assert_eq "functional: llamafile provider has no apiKey" "absent" "$LF_HAS_KEY"

        LF_MODEL_KEY=$(printf '%s' "$LUA_JSON_FUNC" | jq -r '.provider["workspace-gw-llamafile"].models | keys[0]' 2>/dev/null || echo "")
        assert_eq "functional: llamafile model key is raw id" "/zip/MiniCPM5-1B-Q8_0.gguf" "$LF_MODEL_KEY"

        LF_MODEL_NAME=$(printf '%s' "$LUA_JSON_FUNC" | jq -r '.provider["workspace-gw-llamafile"].models["/zip/MiniCPM5-1B-Q8_0.gguf"].name' 2>/dev/null || echo "")
        assert_eq "functional: llamafile model display name is MiniCPM5" "MiniCPM5" "$LF_MODEL_NAME"

        LF_MODEL_CTX=$(printf '%s' "$LUA_JSON_FUNC" | jq -r '.provider["workspace-gw-llamafile"].models["/zip/MiniCPM5-1B-Q8_0.gguf"].limit.context' 2>/dev/null || echo "")
        assert_eq "functional: llamafile model context is 128000" "128000" "$LF_MODEL_CTX"

        # Verify the other two providers still exist
        PRIV_NAME=$(printf '%s' "$LUA_JSON_FUNC" | jq -r '.provider["workspace-gw-private"].name' 2>/dev/null || echo "")
        assert_eq "functional: private provider name" "Workspace GW (Virtual Key)" "$PRIV_NAME"

        OWN_NAME=$(printf '%s' "$LUA_JSON_FUNC" | jq -r '.provider["workspace-gw-own"].name' 2>/dev/null || echo "")
        assert_eq "functional: own provider name" "Workspace GW (Own Key)" "$OWN_NAME"
    fi
fi

echo ""
echo "sync-opencode-models tests: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi