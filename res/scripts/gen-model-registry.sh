#!/usr/bin/env bash
# gen-model-registry.sh
# Codegen for the canonical model registry.
#
# Source of truth: conf/model-registry.yaml
# Outputs:
#   plugins/custom/model_registry.lua  (Lua module used by APISIX plugins)
#   conf/vector.toml GENERATED block   (VRL remap for request_log.model)
#
# Usage:
#   gen-model-registry.sh [--write]   regenerate outputs in place (default)
#   gen-model-registry.sh --check     regenerate to temp and diff; exit 1 on drift
#
# Editing generated artifacts by hand is forbidden; CI runs --check.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

REGISTRY_YAML="$REPO_ROOT/conf/model-registry.yaml"
LUA_OUT="$REPO_ROOT/plugins/custom/model_registry.lua"
VECTOR_TOML="$REPO_ROOT/conf/vector.toml"

MODE="write"
if [ "${1:-}" = "--check" ]; then
    MODE="check"
elif [ "${1:-}" != "" ] && [ "${1:-}" != "--write" ]; then
    echo "Usage: $0 [--write|--check]" >&2
    exit 2
fi

# shellcheck source=../../tests/config/yaml_helpers.sh
source "$REPO_ROOT/tests/config/yaml_helpers.sh" || exit 1

if [ ! -f "$REGISTRY_YAML" ]; then
    echo "[FAIL] registry not found: $REGISTRY_YAML" >&2
    exit 1
fi

JSON="$(yaml_to_json "$REGISTRY_YAML")"
if [ -z "$JSON" ]; then
    echo "[FAIL] could not parse $REGISTRY_YAML" >&2
    exit 1
fi

# Validate: canonical ids must already be lowercase; aliases must contain
# only characters that are safe inside Lua long-bracket-free string literals
# and VRL quoted keys.
BAD_CANON="$(echo "$JSON" | jq -r '.models | keys[] | select(. != ascii_downcase)')"
if [ -n "$BAD_CANON" ]; then
    echo "[FAIL] canonical ids must be lowercase: $BAD_CANON" >&2
    exit 1
fi

BAD_ALIAS="$(echo "$JSON" | jq -r '.models | to_entries[] | .value.aliases[]? | ascii_downcase | select(test("^[a-z0-9._/-]+$") | not)')"
if [ -n "$BAD_ALIAS" ]; then
    echo "[FAIL] aliases contain unsafe characters: $BAD_ALIAS" >&2
    exit 1
fi

# Flat alias->canonical pairs (aliases lowercased; canonical maps to itself).
PAIRS_JSON="$(echo "$JSON" | jq -c '
    [ .models | to_entries[] | .key as $c
      | ([$c] + [(.value.aliases // [])[] | ascii_downcase])[]
      | {key: ., value: $c} ]
    | sort_by(.key)
    | from_entries')"

ALIAS_COUNT="$(echo "$PAIRS_JSON" | jq 'length')"
if [ "$ALIAS_COUNT" -eq 0 ]; then
    echo "[FAIL] registry produced empty alias map" >&2
    exit 1
fi

render_lua() {
    local out="$1"
    {
        echo "-- GENERATED FILE - DO NOT EDIT."
        echo "-- Source: conf/model-registry.yaml"
        echo "-- Regenerate: res/scripts/gen-model-registry.sh"
        echo "-- Single source of truth for model canonicalization. Used by"
        echo "-- cost_calc.lua, sse-usage.lua and provider_sync_catalog.lua."
        echo "local M = {}"
        echo ""
        echo "local alias_map = {"
        echo "$PAIRS_JSON" | jq -r 'to_entries[] | "    [\"" + .key + "\"] = \"" + .value + "\","'
        echo "}"
        echo "M.alias_map = alias_map"
        echo ""
        cat <<'LUA'
local function last_segment(id)
    local slash = id:reverse():find("/", 1, true)
    if slash then
        return id:sub(#id - slash + 2)
    end
    return id
end
M.last_segment = last_segment

--Canonicalize any observed model string (request body or upstream echo)
--to its models.dev-style canonical id:
--  1. lowercase, exact alias-map hit (covers full paths like
--     "accounts/fireworks/models/glm-5p2" and "frank/glm-5.2")
--  2. last "/" segment alias-map hit (covers "provider/alias" forms)
--  3. otherwise the lowercased last segment (unknown models pass through
--     unchanged so new models never break logging)
function M.canonical(name)
    if not name or name == "" then
        return ""
    end
    local lower = tostring(name):lower()
    local hit = alias_map[lower]
    if hit then
        return hit
    end
    local seg = last_segment(lower)
    return alias_map[seg] or seg
end

function M.is_canonical(id)
    return alias_map[id] == id
end

return M
LUA
    } > "$out"
}

render_vrl_block() {
    local out="$1"
    local map_literal
    map_literal="$(echo "$PAIRS_JSON" | jq -r 'to_entries | map("\"" + .key + "\": \"" + .value + "\"") | join(", ")')"
    {
        echo "# Model canonicalization - GENERATED from conf/model-registry.yaml."
        echo "# Algorithm mirrors plugins/custom/model_registry.lua M.canonical:"
        echo "# exact lowercase hit, else last-slash-segment hit, else last segment."
        echo "model_lower = downcase(model_raw)"
        echo "model_alias_map = { ${map_literal} }"
        echo "model_canon = get(model_alias_map, [model_lower]) ?? null"
        echo "if model_canon == null {"
        echo "  model_seg_caps = parse_regex(model_lower, r'(?P<model>[^/]+)\$') ?? null"
        echo "  model_seg = if model_seg_caps != null { to_string(model_seg_caps.model) } else { model_lower }"
        echo "  model_canon = get(model_alias_map, [model_seg]) ?? model_seg"
        echo "}"
    } > "$out"
}

inject_vector() {
    local src="$1"
    local block_file="$2"
    local dst="$3"
    awk -v block_file="$block_file" '
        /^# BEGIN GENERATED MODEL CANONICALIZATION/ {
            print
            while ((getline line < block_file) > 0) print line
            close(block_file)
            skip = 1
            next
        }
        /^# END GENERATED MODEL CANONICALIZATION/ {
            skip = 0
            print
            next
        }
        !skip { print }
    ' "$src" > "$dst"
}

if [ "$MODE" = "write" ]; then
    TMP_BLOCK="$(mktemp)"
    render_lua "$LUA_OUT"
    render_vrl_block "$TMP_BLOCK"
    TMP_VEC="$(mktemp)"
    inject_vector "$VECTOR_TOML" "$TMP_BLOCK" "$TMP_VEC"
    if ! grep -q 'model_alias_map' "$TMP_VEC"; then
        echo "[FAIL] generated VRL block did not land in vector.toml (markers missing?)" >&2
        rm -f "$TMP_BLOCK" "$TMP_VEC"
        exit 1
    fi
    mv "$TMP_VEC" "$VECTOR_TOML"
    rm -f "$TMP_BLOCK"
    echo "[OK] generated $LUA_OUT ($ALIAS_COUNT alias entries)"
    echo "[OK] generated VRL block in $VECTOR_TOML"
else
    TMP_DIR="$(mktemp -d)"
    render_lua "$TMP_DIR/model_registry.lua"
    render_vrl_block "$TMP_DIR/block.vrl"
    inject_vector "$VECTOR_TOML" "$TMP_DIR/block.vrl" "$TMP_DIR/vector.toml"
    rc=0
    if ! diff -u "$LUA_OUT" "$TMP_DIR/model_registry.lua" > "$TMP_DIR/lua.diff"; then
        echo "[FAIL] $LUA_OUT is out of sync with conf/model-registry.yaml:" >&2
        cat "$TMP_DIR/lua.diff" >&2
        rc=1
    fi
    if ! diff -u "$VECTOR_TOML" "$TMP_DIR/vector.toml" > "$TMP_DIR/vec.diff"; then
        echo "[FAIL] $VECTOR_TOML GENERATED block is out of sync with conf/model-registry.yaml:" >&2
        cat "$TMP_DIR/vec.diff" >&2
        rc=1
    fi
    if [ "$rc" -eq 0 ]; then
        echo "[PASS] generated artifacts in sync with conf/model-registry.yaml"
    else
        echo "Run: res/scripts/gen-model-registry.sh" >&2
    fi
    rm -rf "$TMP_DIR"
    exit "$rc"
fi
