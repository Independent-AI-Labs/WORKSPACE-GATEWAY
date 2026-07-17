#!/bin/bash
set -euo pipefail

# tests/config/test_model_registry.sh
# Guards the canonical model registry (conf/model-registry.yaml) and the
# single-writer / single-normalizer architecture:
#
#   1. Functional: model_registry.canonical() maps every known alias
#      variant to its canonical models.dev-style id (runs in container
#      LuaJIT, no stack required).
#   2. Drift: generated artifacts (model_registry.lua, vector.toml
#      GENERATED block) are in sync with the YAML (gen --check).
#   3. Single-writer: pricing:* dict keys are written ONLY by
#      provider_sync_catalog.lua; cost_calc.lua has no models.dev fetch.
#   4. Single-normalizer: canonicalization logic lives ONLY in
#      model_registry.lua; no other plugin lowercases/strip-slashes model
#      names; vector.toml normalization exists only inside the GENERATED
#      block.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
IMAGE="apache/apisix:3.17.0-debian"

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
    echo "test_model_registry.sh: $pass passed, $fail failed"
    if [ "$fail" -gt 0 ]; then
        exit 1
    fi
}

# ---------- 1. functional canonical() tests ----------
LUA_OUTPUT=$(podman run --rm \
    -v "$REPO_ROOT/plugins/custom:/plugins/custom:ro" \
    --entrypoint /usr/local/openresty/luajit/bin/luajit \
    "$IMAGE" \
    -e '
package.path = "/plugins/custom/?.lua;" .. package.path
local r = require("model_registry")
local pass, fail = 0, 0
local function check(desc, expected, actual)
    if expected == actual then pass = pass + 1; print("[PASS] " .. desc)
    else fail = fail + 1; print("[FAIL] " .. desc .. " -- expected: " .. tostring(expected) .. ", actual: " .. tostring(actual)) end
end

-- exact alias hits (lowercased full string)
check("frank/GLM-5.2 -> glm-5.2", "glm-5.2", r.canonical("frank/GLM-5.2"))
check("accounts/fireworks/models/glm-5p2 -> glm-5.2", "glm-5.2", r.canonical("accounts/fireworks/models/glm-5p2"))
check("Accounts/Fireworks/Models/GLM-5P2 -> glm-5.2", "glm-5.2", r.canonical("Accounts/Fireworks/Models/GLM-5P2"))
check("glm-5p2 -> glm-5.2", "glm-5.2", r.canonical("glm-5p2"))
check("z-ai/glm-5.2 -> glm-5.2", "glm-5.2", r.canonical("z-ai/glm-5.2"))
check("glm-5p1 -> glm-5.1", "glm-5.1", r.canonical("glm-5p1"))
check("kimi-for-coding -> kimi-k2.7-code", "kimi-k2.7-code", r.canonical("kimi-for-coding"))
check("k3 -> kimi-k2.7-code", "kimi-k2.7-code", r.canonical("k3"))
check("moonshotai/kimi-k2.7-code -> kimi-k2.7-code", "kimi-k2.7-code", r.canonical("moonshotai/kimi-k2.7-code"))
check("/zip/MiniCPM5-1B-Q8_0.gguf -> minicpm5-1b-q8_0.gguf", "minicpm5-1b-q8_0.gguf", r.canonical("/zip/MiniCPM5-1B-Q8_0.gguf"))

-- canonical ids are stable
check("glm-5.2 stays glm-5.2", "glm-5.2", r.canonical("glm-5.2"))
check("GLM-5.2 -> glm-5.2", "glm-5.2", r.canonical("GLM-5.2"))
check("kimi-k2.7-code stays", "kimi-k2.7-code", r.canonical("kimi-k2.7-code"))

-- last-segment alias hit (unknown provider prefix + known alias)
check("someprovider/kimi-for-coding -> kimi-k2.7-code", "kimi-k2.7-code", r.canonical("someprovider/kimi-for-coding"))
check("vercel/zai/glm-5.2 -> glm-5.2 (seg hit)", "glm-5.2", r.canonical("vercel/zai/glm-5.2"))

-- unknown models pass through as lowercase last segment
check("unknown-model passes through", "unknown-model", r.canonical("unknown-model"))
check("upstream/Model-X -> model-x", "model-x", r.canonical("upstream/Model-X"))
check("gw-integration-seed-model passes through", "gw-integration-seed-model", r.canonical("gw-integration-seed-model"))

-- edge cases
check("empty -> empty", "", r.canonical(""))
check("nil -> empty", "", r.canonical(nil))
check("is_canonical(glm-5.2)", true, r.is_canonical("glm-5.2"))
check("is_canonical(glm-5p2) is false", false, r.is_canonical("glm-5p2"))

io.stderr:write(string.format("LUA_RESULTS:%d,%d\n", pass, fail))
' 2>&1)

echo "$LUA_OUTPUT" | grep -E '^\[(PASS|FAIL)\]'

LUA_RESULTS=$(echo "$LUA_OUTPUT" | grep 'LUA_RESULTS:' | sed 's/.*LUA_RESULTS://')
LUA_PASS=$(echo "$LUA_RESULTS" | cut -d, -f1)
LUA_FAIL=$(echo "$LUA_RESULTS" | cut -d, -f2)
pass=$((pass + ${LUA_PASS:-0}))
fail=$((fail + ${LUA_FAIL:-0}))

# ---------- 2. codegen drift check ----------
if GEN_OUT=$(bash "$REPO_ROOT/res/scripts/gen-model-registry.sh" --check 2>&1); then
    echo "[PASS] generated artifacts in sync with conf/model-registry.yaml"
    pass=$((pass + 1))
else
    echo "[FAIL] generated artifacts out of sync -- run res/scripts/gen-model-registry.sh"
    echo "$GEN_OUT"
    fail=$((fail + 1))
fi

# ---------- 3. single-writer guards ----------
PRICING_WRITERS=$(grep -rln 'dict:set("pricing:"' "$REPO_ROOT/plugins/custom/" | tr '\n' ' ')
assert_eq "only provider_sync_pricing.lua writes pricing:* keys" \
    "$REPO_ROOT/plugins/custom/provider_sync_pricing.lua " "$PRICING_WRITERS"

MODELS_DEV_FETCHES=$(grep -rl 'models.dev/api.json' "$REPO_ROOT/plugins/custom/" | tr '\n' ' ')
assert_eq "only provider_sync_catalog.lua references models.dev" \
    "$REPO_ROOT/plugins/custom/provider_sync_catalog.lua " "$MODELS_DEV_FETCHES"

# ---------- 4. single-normalizer guards ----------
NORMALIZE_DEFS=$(grep -rln 'function.*normalize_key\|function.*canonical' "$REPO_ROOT/plugins/custom/" | tr '\n' ' ')
assert_eq "canonicalization defined only in model_registry.lua" \
    "$REPO_ROOT/plugins/custom/model_registry.lua " "$NORMALIZE_DEFS"

COST_CALC_NORMALIZE=$(grep -c 'normalize_key' "$REPO_ROOT/plugins/custom/cost_calc.lua" || true)
assert_eq "cost_calc.lua has no normalize_key" "0" "$COST_CALC_NORMALIZE"

SSE_USAGE_NORMALIZE=$(grep -c 'normalize_key' "$REPO_ROOT/plugins/custom/sse-usage.lua" || true)
assert_eq "sse-usage.lua has no normalize_key" "0" "$SSE_USAGE_NORMALIZE"

# vector.toml: the last-slash regex must appear only inside GENERATED block
VECTOR_TOML="$REPO_ROOT/conf/vector.toml"
REGEX_COUNT=$(grep -c 'parse_regex(model_lower' "$VECTOR_TOML" || true)
assert_eq "vector.toml model regex exactly once (generated block)" "1" "$REGEX_COUNT"
OLD_VRL=$(grep -c 'parse_regex(model_norm' "$VECTOR_TOML" || true)
assert_eq "vector.toml has no hand-written model_norm remap" "0" "$OLD_VRL"

summary
