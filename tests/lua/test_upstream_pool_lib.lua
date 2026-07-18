local pool_lib = require("upstream_pool_lib")

local pass = 0
local fail = 0

local function check(cond, msg)
    if cond then
        pass = pass + 1
    else
        fail = fail + 1
        io.stderr:write("[FAIL] " .. msg .. "\n")
    end
end

local function assert_eq(actual, expected, msg)
    check(actual == expected, msg .. " expected=" .. tostring(expected) .. " actual=" .. tostring(actual))
end

local function status_in_tests()
    check(pool_lib.status_in({429}, 429), "status_in: match")
    check(not pool_lib.status_in({429}, 403), "status_in: no match")
    check(pool_lib.status_in({402, 403}, 403), "status_in: second element")
    check(not pool_lib.status_in(nil, 429), "status_in: nil list")
    check(not pool_lib.status_in({429}, "abc"), "status_in: non-numeric status")
    check(pool_lib.status_in({429}, "429"), "status_in: string status coerced")
end

local function defaults_tests()
    assert_eq(pool_lib.cooldown_s({}), 3600, "cooldown_s default")
    assert_eq(pool_lib.cooldown_s({cooldown_s = 60}), 60, "cooldown_s override")
    assert_eq(pool_lib.cooldown_s({cooldown_s = -5}), 3600, "cooldown_s invalid falls back")
    assert_eq(pool_lib.cooldown_on({})[1], 429, "cooldown_on default")
    assert_eq(pool_lib.disable_on({})[1], 402, "disable_on default [1]")
    assert_eq(pool_lib.disable_on({})[2], 403, "disable_on default [2]")
    assert_eq(pool_lib.cooldown_on({cooldown_on = {500}})[1], 500, "cooldown_on override")
end

local function select_sticky_tests()
    local pool = {keys = {
        {id = "k1", key = "sk-one", active = true},
        {id = "k2", key = "sk-two", active = true},
    }}

    local entry = pool_lib.select_sticky(pool, nil)
    assert_eq(entry and entry.id, "k1", "sticky picks first active key")

    entry = pool_lib.select_sticky(pool, function(id) return id == "k1" end)
    assert_eq(entry and entry.id, "k2", "sticky skips unavailable key")

    entry = pool_lib.select_sticky(pool, function() return true end)
    check(entry == nil, "sticky returns nil when all unavailable")

    pool.keys[1].active = false
    entry = pool_lib.select_sticky(pool, nil)
    assert_eq(entry and entry.id, "k2", "sticky skips inactive key")

    check(pool_lib.select_sticky({}, nil) == nil, "sticky nil on empty pool")
    check(pool_lib.select_sticky(nil, nil) == nil, "sticky nil on nil pool")

    local nokey = {keys = {{id = "k1", key = "", active = true}}}
    check(pool_lib.select_sticky(nokey, nil) == nil, "sticky skips empty key material")
end

local function mark_disabled_tests()
    local pool = {keys = {
        {id = "k1", key = "sk-one", active = true},
        {id = "k2", key = "sk-two", active = true},
    }}
    local updated = pool_lib.mark_disabled(pool, "k1")
    check(updated ~= nil, "mark_disabled returns pool")
    check(updated.keys[1].active == false, "mark_disabled flips active")
    check(updated.keys[2].active == true, "mark_disabled leaves others")

    check(pool_lib.mark_disabled(pool, "nope") == nil, "mark_disabled nil on unknown id")
    check(pool_lib.mark_disabled({}, "k1") == nil, "mark_disabled nil on empty pool")
end

status_in_tests()
defaults_tests()
select_sticky_tests()
mark_disabled_tests()

io.stderr:write(string.format("[test_upstream_pool_lib] %d passed, %d failed\n", pass, fail))
if fail > 0 then
    os.exit(1)
end
