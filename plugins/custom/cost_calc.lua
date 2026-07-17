--plugins/custom/cost_calc.lua   (repo source path)
--Deployed to: /usr/local/apisix/apisix/plugins/cost_calc.lua  (flat, no custom/ subdir)
--Required as: require("apisix.plugins.cost_calc")
--Pure module, NOT an APISIX plugin. Required by sse-usage.lua in the log phase.
--No plugin = no schema, no priority, no phase bindings.
--
--READ-ONLY pricing consumer. The ONLY writer of pricing:* keys in the
--gateway-cache shared dict is provider_sync_catalog.lua (single-writer
--rule, enforced by tests/config/test_model_registry.sh). This module never
--fetches models.dev itself; on a cache miss it triggers provider-sync.
--
--Model identity comes from model_registry.lua (generated from
--conf/model-registry.yaml). All pricing lookups are keyed by the
--canonical model id; there is no local normalization logic here.
--
--Dependency strategy: APISIX/OpenResty-specific modules (apisix.core,
--cjson.safe) and the ngx global are deferred-required inside the functions
--that use them, NOT at module top level. This keeps compute_cost and
--resolve_cost (upstream + unknown branches) loadable and runnable in
--plain LuaJIT without the nginx worker runtime, so the unit test suite
--(tests/config/test_cost_calc.sh) runs with zero dependency injection.

local model_registry
do
    local ok, mod = pcall(require, "apisix.plugins.model_registry")
    if ok then
        model_registry = mod
    else
        model_registry = require("model_registry")
    end
end

local M = {}

local SHARED_DICT = "gateway-cache"
local PRICING_KEY_PREFIX = "pricing:"
local PROVIDER_SYNC_TS_KEY = "providers:ts"

M.SOURCE_UPSTREAM = "upstream"
M.SOURCE_COMPUTED = "computed"
M.SOURCE_UNKNOWN = "unknown"

local function get_dict()
    if not ngx or not ngx.shared then return nil end
    return ngx.shared[SHARED_DICT]
end

local function get_core()
    return require("apisix.core")
end

local function get_provider_sync()
    local ok, mod = pcall(require, "apisix.plugins.provider-sync")
    if ok then return mod end
    ok, mod = pcall(require, "provider-sync")
    if ok then return mod end
    return nil
end

function M.get_pricing(model_id)
    local dict = get_dict()
    if not dict then
        return nil, "miss"
    end

    local key = model_registry.canonical(model_id)
    if key == "" then
        return nil, "miss"
    end

    local raw = dict:get(PRICING_KEY_PREFIX .. key)
    if not raw then
        --Provider-sync is the sole pricing writer. If it has already run,
        --a missing price means this model is not catalogued.
        local provider_sync_ts = dict:get(PROVIDER_SYNC_TS_KEY)
        if provider_sync_ts then
            return nil, "miss"
        end

        --Provider-sync has not run yet; trigger it once. The catalog
        --owns all sync defaults (providers dir, models.dev URL, TTLs).
        local provider_sync = get_provider_sync()
        if provider_sync and provider_sync.sync then
            local ok = pcall(provider_sync.sync, {})
            if ok then
                raw = dict:get(PRICING_KEY_PREFIX .. key)
                if not raw then
                    return nil, "miss"
                end
            end
        end

        if not raw then
            get_core().log.warn("cost_calc: no pricing for '", key,
                "' and provider-sync unavailable")
            return nil, "miss"
        end
    end

    local cjson = require("cjson.safe")
    local price = cjson.decode(raw)
    if type(price) ~= "table" or type(price.input) ~= "number" then
        return nil, "miss"
    end

    return price, "fresh"
end

function M.compute_cost(tokens, price)
    if not tokens or not price then return 0 end

    local pt = tonumber(tokens.pt) or 0
    local ct = tonumber(tokens.ct) or 0
    local cached = tonumber(tokens.cached) or 0
    local reasoning = tonumber(tokens.reasoning) or 0

    local input_rate = tonumber(price.input) or 0
    local output_rate = tonumber(price.output) or 0
    local cache_read_rate = tonumber(price.cache_read) or 0
    local reasoning_rate = tonumber(price.reasoning) or output_rate

    local input_uncached = pt - cached
    if input_uncached < 0 then input_uncached = 0 end

    local output_non_reasoning = ct - reasoning
    if output_non_reasoning < 0 then output_non_reasoning = 0 end

    local cost = input_uncached * input_rate / 1e6
               + output_non_reasoning * output_rate / 1e6
               + cached * cache_read_rate / 1e6
               + reasoning * reasoning_rate / 1e6

    return cost
end

function M.resolve_cost(sse_cost, tokens, model_id)
    if sse_cost and tonumber(sse_cost) and tonumber(sse_cost) > 0 then
        return tonumber(sse_cost), M.SOURCE_UPSTREAM
    end

    local price, _ = M.get_pricing(model_id)
    if not price then
        return 0, M.SOURCE_UNKNOWN
    end

    return M.compute_cost(tokens, price), M.SOURCE_COMPUTED
end

return M
