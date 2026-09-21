--plugins/custom/provider_sync_pricing.lua
--Pricing writer for provider-sync, split out of provider_sync_catalog.lua
--(512-line file limit). Sole writer of pricing:* keys in the shared dict
--(single-writer rule, enforced by tests/config/test_model_registry.sh).
local cjson = require("cjson.safe")
local model_registry = require("apisix.plugins.model_registry")
local pricing_resolver = require("apisix.plugins.provider_pricing")

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

local function get_core()
    return require("apisix.core")
end

--A cache rate must never make tokens free (FR-3.3). models.dev omits the
--field for most providers and publishes an explicit 0 for zai, so a nil or
--non-positive catalog rate is published at the input rate. input can be 0
--only for a genuinely free model.
local function billable_rate(value, floor_rate)
    local rate = tonumber(value)
    if rate and rate > 0 then return rate end
    return floor_rate
end

--Fill each model's cost from the provider's single declared pricing source.
--provider.pricing.source.provider names the models.dev namespace whose prices
--apply (e.g. "opencode-go" for the relay, "moonshotai" for Kimi). There is no
--cross-provider merge and no metadata-joined or endpoint-reported cost.
function M.apply_cost_source(provider, models, models_dev)
    local namespace = provider.pricing and provider.pricing.source
        and provider.pricing.source.provider or nil
    for model_id, entry in pairs(models) do
        local cost, provenance = pricing_resolver.resolve(
            provider, model_id, models_dev)
        if cost then
            entry.cost = cost
            entry.pricing = {
                source = provenance,
                provider = namespace,
            }
        else
            --A price that no longer resolves must not linger on the entry.
            entry.cost = nil
            entry.pricing = nil
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
                    local pricing_source = model.pricing and model.pricing.source
                    if key ~= "" and not written[scoped_key] then
                        if pricing_source ~= "provider_override"
                            and pricing_source ~= "models_dev" then
                            --A price with no recognized provenance would
                            --publish an unlabelable cost_source. Refuse it and
                            --name the writer contract violation.
                            get_core().log.error(
                                "provider_sync: refusing to publish price for '",
                                model_id, "' under '", provider_id,
                                "': unrecognized provenance '",
                                tostring(pricing_source), "'")
                        else
                            written[scoped_key] = true
                            local input = tonumber(model.cost.input) or 0
                            local output = tonumber(model.cost.output) or 0
                            local price = {
                                provider = provider_id,
                                pricing_source = pricing_source,
                                input = input,
                                output = output,
                                cache_read = billable_rate(
                                    model.cost.cache_read, input),
                                cache_write = billable_rate(
                                    model.cost.cache_write, input),
                                fetched_at = fetched_at,
                            }
                            --Only publish a reasoning rate when the catalog has
                            --one; omitting it makes compute_cost bill reasoning
                            --at the output rate (0 would bill reasoning free).
                            if model.cost.reasoning and model.cost.reasoning > 0 then
                                price.reasoning = model.cost.reasoning
                            end
                            snapshot[scoped_key] = price
                            dict:set("pricing:" .. provider_id .. ":" .. key,
                                cjson.encode(price), DEFAULT_STALE)
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
