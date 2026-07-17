--plugins/custom/provider_sync_pricing.lua
--Pricing writer for provider-sync, split out of provider_sync_catalog.lua
--(512-line file limit). Sole writer of pricing:* keys in the shared dict
--(single-writer rule, enforced by tests/config/test_model_registry.sh).
local cjson = require("cjson.safe")
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
local DEFAULT_STALE = 86400

local function get_dict()
    if not ngx or not ngx.shared then
        return nil
    end
    return ngx.shared[SHARED_DICT]
end

--Fill missing model costs from the provider's declared pricing source.
--provider.cost_source names the models.dev provider id whose prices
--apply to this gateway provider (e.g. "opencode" for the relay,
--"moonshotai" for Kimi). This is the ONLY pricing source; there is no
--cross-provider cheapest-wins merge.
function M.apply_cost_source(provider, models, models_dev)
    local source_id = provider.cost_source
    if not source_id or source_id == "" then
        return
    end
    if not models_dev or type(models_dev) ~= "table" then
        return
    end
    local block = models_dev[source_id]
    if not block or type(block) ~= "table" or type(block.models) ~= "table" then
        return
    end
    for model_id, entry in pairs(models) do
        if not entry.cost then
            local md = block.models[model_id]
                or block.models[model_registry.canonical(model_id)]
            if type(md) == "table" and type(md.cost) == "table" then
                local cost = {
                    input = md.cost.input or 0,
                    output = md.cost.output or 0,
                }
                if md.cost.cache_read ~= nil then
                    cost.cache_read = md.cost.cache_read
                end
                if md.cost.cache_write ~= nil then
                    cost.cache_write = md.cost.cache_write
                end
                entry.cost = cost
            end
        end
    end
end

--Keys are CANONICAL model ids (model_registry.canonical), so every alias
--resolves to the same price and no alias-shaped keys can ever diverge.
--Providers are iterated in sorted order and the first writer wins per
--canonical key, making the cache content deterministic.
function M.populate_pricing_cache(enriched)
    local dict = get_dict()
    if not dict then
        return
    end
    local provider_ids = {}
    for provider_id in pairs(enriched) do
        table.insert(provider_ids, provider_id)
    end
    table.sort(provider_ids)
    local written = {}
    for _, provider_id in ipairs(provider_ids) do
        local provider = enriched[provider_id]
        if provider.models and type(provider.models) == "table" then
            for model_id, model in pairs(provider.models) do
                if model.cost then
                    local key = model_registry.canonical(model_id)
                    if key ~= "" and not written[key] then
                        written[key] = true
                        local price = {
                            provider = provider_id,
                            input = model.cost.input or 0,
                            output = model.cost.output or 0,
                            cache_read = model.cost.cache_read or 0,
                            cache_write = model.cost.cache_write or 0,
                            fetched_at = ngx.time(),
                        }
                        dict:set("pricing:" .. key, cjson.encode(price), DEFAULT_STALE)
                    end
                end
            end
        end
    end
end

return M
