-- Unit tests for res/scripts/cost/recalc.lua (cost recalculation core).
local recalc = require("recalc")

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
    check(actual == expected,
        msg .. " expected=" .. tostring(expected) .. " actual=" .. tostring(actual))
end

local function close(a, b)
    return a ~= nil and math.abs(a - b) < 1e-9
end

local RATES = {
    "workspace-gw-a\tglm-5.2\t1\t2\t0.1\t1.25\t3\tmodels_dev",
    "workspace-gw-b\tglm-5.2\t10\t20\t1\t12.5\t30\tmodels_dev",
    "workspace-gw-a\tz-ai/glm-5\t4\t8\t0.4\t5\t6\tmodels_dev",
    "workspace-gw-opencode-go-api-key\tglm-5.2\t1\t2\t0.1\t1.25\t3\tmodels_dev",
    "workspace-gw-a\tbad-zero\t0\t0\t0\t0\t0\tmodels_dev",
    "workspace-gw-a\tglm-5.2-noreason\t1\t2\t0.1\t1.25\t\tmodels_dev",
    "workspace-gw-a\tglm-5.2-nocache\t1\t2\t0\t0\t3\tmodels_dev",
    "",
}

local function build_tests()
    local prices = recalc.build_prices(RATES)
    check(prices["workspace-gw-a:glm-5.2"] ~= nil, "prices[1] scoped a present")
    check(prices["workspace-gw-b:glm-5.2"] ~= nil, "prices[2] scoped b present")
    -- Alias z-ai/glm-5 canonicalizes to glm-5.
    check(prices["workspace-gw-a:glm-5"] ~= nil, "prices[3] canonicalized key")
    -- Missing/zero input rate must be ignored, never zero out a row.
    check(prices["workspace-gw-a:bad-zero"] == nil, "prices[4] zero-input ignored")
    assert_eq(prices["workspace-gw-a:glm-5.2"].input, 1, "prices[5] scoped rate value")
    -- Absent/zero reasoning rate stays unset (compute_cost falls to output).
    check(prices["workspace-gw-a:glm-5.2-noreason"].reasoning == nil,
        "prices[6] missing reasoning rate unset")
    -- A zero cache rate bills at input, never free, in the emitted tuple too.
    assert_eq(prices["workspace-gw-a:glm-5.2-nocache"].cache_read, 1,
        "prices[7] zero cache_read bills at input")
    assert_eq(prices["workspace-gw-a:glm-5.2-nocache"].cache_write, 1,
        "prices[8] zero cache_write bills at input")
end

local function lookup_tests()
    local prices = recalc.build_prices(RATES)
    assert_eq(recalc.lookup(prices, "workspace-gw-a", "glm-5.2").input, 1, "lookup[1] scoped a")
    assert_eq(recalc.lookup(prices, "workspace-gw-b", "glm-5.2").input, 10, "lookup[2] scoped b")
    -- No cross-provider lookup: a provider absent for this model is a miss.
    check(recalc.lookup(prices, "workspace-gw-c", "glm-5.2") == nil, "lookup[3] no cross-provider")
    -- A missing provider is a miss, exactly like cost_calc.get_pricing.
    check(recalc.lookup(prices, "", "glm-5.2") == nil, "lookup[4] empty provider miss")
end

-- row: event, req, ts, provider, model, pt, ct, total, cached, cwrite, reason, source, cost
local function row(source, cost, provider, model, pt, ct, cached, cwrite, reason)
    return { "e1", "r1", "2026-09-21 00:00:00.000", provider or "workspace-gw-a",
        model or "glm-5.2", tostring(pt or 0), tostring(ct or 0), "0",
        tostring(cached or 0), tostring(cwrite or 0), tostring(reason or 0),
        source, tostring(cost) }
end

local function resolve_tests()
    -- Route is recovered from the event_id suffix when provider_id is empty.
    local r = { "relay-kimi_1755000000", "", "", "", "kimi-k3" }
    assert_eq(recalc.resolve(r), "workspace-gw-kimi-device-oauth", "resolve[1] route")

    -- A prior gateway alias is canonicalized.
    local a = { "ocm_x", "", "", "workspace-gw-own", "glm-5.2" }
    assert_eq(recalc.resolve(a), "workspace-gw-opencode-go-api-key", "resolve[2] alias")

    -- A canonical id passes through untouched.
    local c = { "relay-kimi_1", "", "", "workspace-gw-kimi-device-oauth", "kimi-k3" }
    assert_eq(recalc.resolve(c), "workspace-gw-kimi-device-oauth", "resolve[3] canonical")

    -- An unmapped route and a non-gateway id stay empty/verbatim.
    assert_eq(recalc.resolve({ "relay-nope_1", "", "", "", "kimi-k3" }), "",
        "resolve[4] unknown route stays empty")
    assert_eq(recalc.resolve({ "ocm_y", "", "", "openai", "gpt-5" }), "openai",
        "resolve[5] non-gateway id untouched")
end

local function decide_tests()
    local prices = recalc.build_prices(RATES)

    -- An upstream-reported row is revalued like any other: billed cost is
    -- always the provider-scoped price, never the reported cost.
    local up_reprice = recalc.decide(prices, row("upstream", 1.0), 1e-9)
    check(close(up_reprice, 0.0), "decide[1] upstream-reported row is revalued")
    check(recalc.decide(prices, row("unknown", 0,
        "workspace-gw-c", "glm-5.2"), 1e-9) == nil,
        "decide[2] unpriced provider left alone")
    check(recalc.decide(prices, row("computed", 0.5), 1e-9) ~= nil,
        "decide[3] differing computed row emitted")

    -- Same amount, stale source -> emitted so provenance is corrected.
    local stale = recalc.decide(prices, row("computed", 1.0, nil, nil, 1e6, 0), 1e-9)
    check(close(stale, 1.0), "decide[4] stale source corrected at same cost")

    -- No difference in amount or source -> idempotent no-op.
    local same = recalc.decide(prices, row("models_dev", 1.0, nil, nil, 1e6, 0), 1e-9)
    check(same == nil, "decide[4b] equal cost and source is a no-op")

    -- cache_write separate rate: 4e5 * 1.25 / 1e6 = 0.5 for a-zero row.
    local cw = recalc.decide(prices,
        row("computed", 0, "workspace-gw-a", "glm-5.2", 0, 0, 0, 4e5), 1e-9)
    check(close(cw, 0.5), "decide[5] cache_write billed at its own rate")

    -- A catalog row without a reasoning rate leaves it unset, so reasoning
    -- bills at the output rate (mirrors provider_sync_pricing/compute_cost):
    -- (7e5 + 3e5) * 2 / 1e6 = 2.0.
    local rr = recalc.decide(prices,
        row("computed", 0, "workspace-gw-a", "glm-5.2-noreason",
            0, 1e6, 0, 0, 3e5), 1e-9)
    check(close(rr, 2.0), "decide[8] missing reasoning rate bills at output")

    -- An upstream row only gets its provider backfilled: cost/source stay put.
    local up = { "relay-kimi_1755000000", "r1", "2026-09-21 00:00:00.000", "",
        "kimi-k3", "0", "0", "0", "0", "0", "0", "upstream", "1.5" }
    local up_cost, up_prov = recalc.decide(prices, up, 1e-9)
    check(up_cost == nil and up_prov == "workspace-gw-kimi-device-oauth",
        "decide[6] upstream provider-only backfill")

    -- A prior alias re-prices under the canonical provider.
    local alias = row("unknown", 0, "workspace-gw-own", "glm-5.2", 1e6, 0)
    local alias_cost, alias_prov = recalc.decide(prices, alias, 1e-9)
    check(close(alias_cost, 1.0), "decide[7] alias repriced")
    assert_eq(alias_prov, "workspace-gw-opencode-go-api-key", "decide[7] alias provider")
end

local function main()
    build_tests()
    lookup_tests()
    resolve_tests()
    decide_tests()

    io.write(string.format("\n==== cost recalc tests: %d passed, %d failed ====\n", pass, fail))
    if fail > 0 then
        io.stderr:write(string.format("FAILED: %d test(s) failed\n", fail))
        os.exit(1)
    end
end

main()
