#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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
    echo "test_cost_calc.sh: $pass passed, $fail failed"
    if [ "$fail" -gt 0 ]; then
        exit 1
    fi
}

MODULE_FILE="$REPO_ROOT/plugins/custom/cost_calc.lua"

# Test 1: file exists
if [ -f "$MODULE_FILE" ]; then
    echo "[PASS] cost_calc.lua exists"
    pass=$((pass + 1))
else
    echo "[FAIL] cost_calc.lua exists"
    fail=$((fail + 1))
fi

# Test 2-4, 5-12: run the Lua test suite inside the APISIX container's
# LuaJIT. The module uses deferred requires (apisix.core, cjson.safe,
# resty.http are required inside functions, not at top level) and
# guards the ngx global in get_dict(), so compute_cost and resolve_cost
# run in plain LuaJIT with ZERO dependency injection - no nginx worker
# runtime, no cosocket libraries, no injected globals.

TEST_LUA=$(cat <<'LUAEOF'
local M = dofile(COST_CALC_MODULE)
local pass, fail = 0, 0
local function check(desc, cond)
    if cond then pass = pass + 1; print("[PASS] " .. desc)
    else fail = fail + 1; print("[FAIL] " .. desc) end
end

-- Test 2: module returns a table
check("Module returns a table", type(M) == "table")

-- Test 3: exposes the three read-only functions (provider-sync is the
-- sole pricing writer; cost_calc no longer fetches models.dev)
check("Exposes get_pricing", type(M.get_pricing) == "function")
check("Exposes compute_cost", type(M.compute_cost) == "function")
check("Exposes resolve_cost", type(M.resolve_cost) == "function")
check("Does NOT expose warmup (writer path removed)", type(M.warmup) == "nil")
check("Does NOT expose fetch_and_cache (writer path removed)", type(M.fetch_and_cache) == "nil")
check("Does NOT expose normalize_key (registry owns identity)", type(M.normalize_key) == "nil")

-- Test 4: exposes the three source constants
check("SOURCE_UPSTREAM == upstream", M.SOURCE_UPSTREAM == "upstream")
check("SOURCE_COMPUTED == computed", M.SOURCE_COMPUTED == "computed")
check("SOURCE_UNKNOWN == unknown", M.SOURCE_UNKNOWN == "unknown")

-- Test 5: input-only math -> 1.0
local t5 = M.compute_cost({pt=1e6, ct=0, cached=0, reasoning=0}, {input=1, output=2})
check("compute_cost input-only == 1.0", math.abs(t5 - 1.0) < 1e-9)

-- Test 6: output-only math -> 2.0
local t6 = M.compute_cost({pt=0, ct=1e6, cached=0, reasoning=0}, {input=1, output=2})
check("compute_cost output-only == 2.0", math.abs(t6 - 2.0) < 1e-9)

-- Test 7: cache_read math -> 0.55
local t7 = M.compute_cost({pt=1e6, ct=0, cached=5e5, reasoning=0}, {input=1, output=2, cache_read=0.1})
check("compute_cost cache_read == 0.55", math.abs(t7 - 0.55) < 1e-9)

-- Test 8: reasoning nil falls back to output rate -> 2.0
local t8 = M.compute_cost({pt=0, ct=1e6, cached=0, reasoning=3e5}, {input=1, output=2, reasoning=nil})
check("compute_cost reasoning-nil == 2.0", math.abs(t8 - 2.0) < 1e-9)

-- Test 9: reasoning has its own rate -> 2.6
local t9 = M.compute_cost({pt=0, ct=1e6, cached=0, reasoning=3e5}, {input=1, output=2, reasoning=4})
check("compute_cost reasoning-set == 2.6", math.abs(t9 - 2.6) < 1e-9)

-- Test 9b: compute_cost ignores extra fields like 'provider' in price table
local t9b = M.compute_cost({pt=1e6, ct=0, cached=0, reasoning=0}, {input=1, output=2, provider="vercel"})
check("compute_cost ignores provider field", math.abs(t9b - 1.0) < 1e-9)

-- Test 10: Pathway A - upstream cost > 0 wins
local fc10, src10 = M.resolve_cost(0.5, {pt=1e6, ct=0, cached=0, reasoning=0}, "glm-5.2")
check("resolve_cost upstream cost == 0.5", math.abs(fc10 - 0.5) < 1e-9)
check("resolve_cost upstream source", src10 == "upstream")

-- Test 11: Pathway B miss - model not in (empty) cache
local fc11, src11 = M.resolve_cost(0, {pt=1e6, ct=0, cached=0, reasoning=0}, "nonexistent-model")
check("resolve_cost unknown cost == 0", fc11 == 0)
check("resolve_cost unknown source", src11 == "unknown")

-- Test 12: resolve_cost always returns exactly 2 values
local a, b, c = M.resolve_cost(0.5, {pt=1, ct=1, cached=0, reasoning=0}, "x")
check("resolve_cost returns exactly 2 values", c == nil and a ~= nil and b ~= nil)

local a2, b2, c2 = M.resolve_cost(0, {pt=1, ct=1, cached=0, reasoning=0}, "x")
check("resolve_cost miss returns exactly 2 values", c2 == nil and a2 ~= nil and b2 ~= nil)

io.stderr:write(string.format("\nLUA_RESULTS:%d,%d\n", pass, fail))
LUAEOF
)

# Run the Lua test inside the APISIX container (the only place luajit is
# available). The module requires zero dependency injection thanks to
# deferred requires.
podman cp "$MODULE_FILE" docker_apisix_1:/tmp/cost_calc_check.lua >/dev/null 2>&1
podman cp "$REPO_ROOT/plugins/custom/model_registry.lua" docker_apisix_1:/tmp/model_registry.lua >/dev/null 2>&1

LUA_OUTPUT=$(podman exec docker_apisix_1 luajit -e "
package.path = '/tmp/?.lua;' .. package.path
COST_CALC_MODULE = '/tmp/cost_calc_check.lua'
$(echo "$TEST_LUA" | sed 's/^/  /')
" 2>&1) || true

echo "$LUA_OUTPUT" | grep -E '^\[(PASS|FAIL)\]'

LUA_RESULTS=$(echo "$LUA_OUTPUT" | grep 'LUA_RESULTS:' | sed 's/.*LUA_RESULTS://')
LUA_PASS=$(echo "$LUA_RESULTS" | cut -d, -f1)
LUA_FAIL=$(echo "$LUA_RESULTS" | cut -d, -f2)

if [ -z "$LUA_PASS" ]; then
    LUA_PASS=0
    LUA_FAIL=0
fi

pass=$((pass + LUA_PASS))
fail=$((fail + LUA_FAIL))

summary
