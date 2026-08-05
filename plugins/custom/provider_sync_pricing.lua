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
local pricing_resolver
do
    local ok, mod = pcall(require, "apisix.plugins.provider_pricing")
    if ok then
        pricing_resolver = mod
    else
        pricing_resolver = require("provider_pricing")
    end
end

local M = {}

local SHARED_DICT = "gateway-cache"
local DEFAULT_STALE = 86400
local ACTIVE_SNAPSHOT_KEY = "pricing:snapshot:active"

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
    for model_id, entry in pairs(models) do
        local cost, provenance = pricing_resolver.resolve(
            provider, model_id, entry, models_dev)
        if cost then
            entry.cost = cost
            entry.pricing = {
                source = provenance,
                provider = provider.pricing and provider.pricing.source
                    and provider.pricing.source.provider or provider.cost_source,
            }
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
    local snapshot = {}
    local fetched_at = ngx.time()
    for _, provider_id in ipairs(provider_ids) do
        local provider = enriched[provider_id]
        if provider.models and type(provider.models) == "table" then
            for model_id, model in pairs(provider.models) do
                if model.cost then
                    local key = model_registry.canonical(model_id)
                    local scoped_key = provider_id .. ":" .. key
                    if key ~= "" and not written[scoped_key] then
                        written[scoped_key] = true
                        local price = {
                            provider = provider_id,
                            pricing_source = model.pricing and model.pricing.source
                                or "unscoped",
                            input = model.cost.input or 0,
                            output = model.cost.output or 0,
                            cache_read = model.cost.cache_read or 0,
                            cache_write = model.cost.cache_write or 0,
                            fetched_at = fetched_at,
                        }
                        snapshot[scoped_key] = price
                        dict:set("pricing:" .. provider_id .. ":" .. key,
                            cjson.encode(price), DEFAULT_STALE)
                        --Compatibility key while request provider identity is
                        --available to every telemetry caller.
                        if not dict:get("pricing:" .. key) then
                            dict:set("pricing:" .. key, cjson.encode(price), DEFAULT_STALE)
                        end
                    end
                end
            end
        end
    end
    local generation = tostring(fetched_at)
    dict:set("pricing:snapshot:" .. generation, cjson.encode({
        generation = generation,
        fetched_at = fetched_at,
        prices = snapshot,
    }), DEFAULT_STALE)
    dict:set(ACTIVE_SNAPSHOT_KEY, generation, DEFAULT_STALE)
end

return M
