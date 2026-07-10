-- plugins/custom/cost_calc.lua   (repo source path)
-- Deployed to: /usr/local/apisix/apisix/plugins/cost_calc.lua  (flat, no custom/ subdir)
-- Required as: require("apisix.plugins.cost_calc")
-- Pure module, NOT an APISIX plugin. Required by sse-usage.lua in init() and log phase.
-- No plugin = no schema, no priority, no phase bindings.
--
-- Dependency strategy: APISIX/OpenResty-specific modules (apisix.core,
-- cjson.safe, resty.http) and the ngx global are deferred-required inside the
-- functions that use them, NOT at module top level. This keeps compute_cost
-- and resolve_cost (upstream + unknown branches) loadable and runnable in
-- plain LuaJIT without the nginx worker runtime, so the unit test suite
-- (tests/config/test_cost_calc.sh) runs with zero dependency injection.

local M = {}

local SHARED_DICT = "gateway-cache"
local PRICING_KEY_PREFIX = "pricing:"
local TS_KEY = "pricing:ts"
local LOCK_KEY = "pricing:lock"
local TTL_SECONDS = 3600
local STALE_SECONDS = 86400
local DEFAULT_URL = "https://models.dev/api.json"
local FETCH_TIMEOUT = 10000
local LOCK_TTL = 30

M.TTL_SECONDS = TTL_SECONDS
M.STALE_SECONDS = STALE_SECONDS
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

local function normalize_key(model_id)
    if not model_id or model_id == "" then return "" end
    local key = model_id:lower()
    local slash = key:reverse():find("/")
    if slash then
        key = key:sub(#key - slash + 2)
    end
    return key
end
M.normalize_key = normalize_key

function M.warmup(models_dev_url)
    local url = models_dev_url or DEFAULT_URL
    local dict = get_dict()
    if not dict then
        local core = get_core()
        core.log.warn("cost_calc: shared dict '", SHARED_DICT, "' not found - is config.yaml custom_lua_shared_dict set?")
        return nil, "shared dict not found"
    end
    if not ngx or not ngx.timer then
        local core = get_core()
        core.log.warn("cost_calc: ngx.timer not available in this context")
        return nil, "ngx.timer not available"
    end
    local ok, err = ngx.timer.at(0, function(premature)
        if premature then return end
        M.fetch_and_cache(url)
    end)
    if not ok then
        local core = get_core()
        core.log.warn("cost_calc: failed to spawn warmup timer: ", err)
        return nil, err
    end
    return true
end

function M.fetch_and_cache(models_dev_url)
    local url = models_dev_url or DEFAULT_URL
    local dict = get_dict()
    if not dict then
        local core = get_core()
        core.log.warn("cost_calc: shared dict not found in fetch_and_cache")
        return nil, "shared dict not found"
    end

    local added, err = dict:add(LOCK_KEY, "1", LOCK_TTL)
    if not added then
        return nil, "lock held"
    end

    local http = require("resty.http")
    local cjson = require("cjson.safe")
    local core = get_core()

    local httpc = http.new()
    httpc:set_timeout(FETCH_TIMEOUT)
    local res, http_err = httpc:request_uri(url, { method = "GET" })

    if not res then
        core.log.warn("cost_calc: models.dev fetch failed: ", http_err)
        dict:delete(LOCK_KEY)
        return nil, http_err
    end

    if res.status ~= 200 then
        core.log.warn("cost_calc: models.dev returned status ", res.status)
        dict:delete(LOCK_KEY)
        return nil, "http " .. res.status
    end

    local body = res.body
    if not body or body == "" then
        core.log.warn("cost_calc: models.dev returned empty body")
        dict:delete(LOCK_KEY)
        return nil, "empty body"
    end

    local data = cjson.decode(body)
    if not data or type(data) ~= "table" then
        core.log.warn("cost_calc: models.dev JSON decode failed")
        dict:delete(LOCK_KEY)
        return nil, "json decode failed"
    end

    local pricing_map = {}
    local count = 0
    for provider_id, provider in pairs(data) do
        if type(provider) == "table" and type(provider.models) == "table" then
            for model_id, model in pairs(provider.models) do
                if type(model) == "table" and type(model.cost) == "table" then
                    local cost = model.cost
                    local key = normalize_key(model_id)
                    if key ~= "" then
                        local input_rate = tonumber(cost.input) or 0
                        local output_rate = tonumber(cost.output) or 0

                        if not (input_rate == 0 and output_rate == 0) then
                            local price = {
                                provider = provider_id,
                                input = input_rate,
                                output = output_rate,
                                cache_read = tonumber(cost.cache_read) or 0,
                                cache_write = tonumber(cost.cache_write) or 0,
                            }
                            local reasoning = tonumber(cost.reasoning)
                            if reasoning then
                                price.reasoning = reasoning
                            end
                            price.fetched_at = ngx.time()
                            if not pricing_map[key] then
                                pricing_map[key] = {}
                            end
                            table.insert(pricing_map[key], price)
                            count = count + 1
                        end
                    end
                end
            end
        end
    end

    local stored = 0
    for key, prices in pairs(pricing_map) do
        table.sort(prices, function(a, b)
            return (a.input or 0) < (b.input or 0)
        end)
        dict:set(PRICING_KEY_PREFIX .. key, cjson.encode(prices), STALE_SECONDS)
        stored = stored + 1
    end

    dict:set(TS_KEY, tostring(ngx.time()), STALE_SECONDS)
    dict:delete(LOCK_KEY)
    core.log.info("cost_calc: cached ", stored, " model pricing entries (", count, " provider entries) from models.dev")
    return true
end

function M.get_pricing(model_id)
    local dict = get_dict()
    if not dict then
        return nil, "miss"
    end

    local key = normalize_key(model_id)
    if key == "" then
        return nil, "miss"
    end

    local raw = dict:get(PRICING_KEY_PREFIX .. key)
    if not raw then
        local ts_str = dict:get(TS_KEY)
        if not ts_str then
            M.warmup()
        end
        return nil, "miss"
    end

    local cjson = require("cjson.safe")
    local decoded = cjson.decode(raw)
    if not decoded then
        return nil, "miss"
    end

    local price
    if decoded[1] then
        price = decoded[1]
    elseif type(decoded.input) == "number" then
        price = decoded
    else
        return nil, "miss"
    end

    local fetched_at = tonumber(price.fetched_at) or 0
    local now = ngx.time()
    if now - fetched_at > TTL_SECONDS then
        M.warmup()
        return price, "stale"
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
