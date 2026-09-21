-- Shared pricing source resolution for provider catalog generation.
-- This module is pure: it does not access ngx, shared dictionaries, or the
-- network. Callers provide the provider definition and models.dev snapshot.
--
-- Billed price precedence is exactly two steps (REQ-PROVIDER-SYNC FR-3.4):
--   1. the provider YAML's `pricing.overrides` entry for the canonical model
--      id (the only manual price declaration channel);
--   2. models.dev inside the provider's single declared `pricing.source`
--      namespace.
-- There is no field-level merge, no candidate-id scan, no cross-provider
-- lookup, and no metadata-joined or endpoint-reported cost.

local registry = require("apisix.plugins.model_registry")

local M = {}

local RATE_FIELDS = {
    "input", "output", "reasoning", "cache_read", "cache_write",
    "input_audio", "output_audio",
}

local function number_or_nil(value)
    if value == nil then return nil end
    local number = tonumber(value)
    if not number or number < 0 then return nil end
    return number
end

local function copy_rates(source)
    if type(source) ~= "table" then return nil end
    local rates = {}
    for _, field in ipairs(RATE_FIELDS) do
        local value = number_or_nil(source[field])
        if value ~= nil then rates[field] = value end
    end
    if next(rates) == nil then return nil end
    if source.tiers ~= nil then rates.tiers = source.tiers end
    if source.context_over_200k ~= nil then
        rates.context_over_200k = source.context_over_200k
    end
    return rates
end

--The declared models.dev namespace, or nil when the provider declares none.
--`pricing.source.provider` is the single source; a type of `unknown` means
--the provider is deliberately unpriced from models.dev.
local function declared_namespace(provider)
    local pricing = provider.pricing or {}
    local source = pricing.source or {}
    if source.type == "unknown" then return nil end
    local namespace = source.provider
    if type(namespace) ~= "string" or namespace == "" then return nil end
    return namespace
end

local function override_for(provider, model_key)
    local pricing = provider.pricing or {}
    local overrides = pricing.overrides
    if type(overrides) ~= "table" then return nil end
    return copy_rates(overrides[model_key])
end

local function models_dev_for(models_dev, namespace, model_key)
    if not namespace or type(models_dev) ~= "table" then return nil end
    local block = models_dev[namespace]
    if type(block) ~= "table" or type(block.models) ~= "table" then return nil end
    local model = block.models[model_key]
    if type(model) ~= "table" then return nil end
    return copy_rates(model.cost)
end

--A provider may declare a model alias whose target is not in the global
--registry (provider.model_aliases). The alias bills at its target's price, so
--resolve the target id before canonicalizing. This is id resolution, not a
--third price step.
local function alias_target(provider, model_id)
    local aliases = provider.model_aliases
    if type(aliases) ~= "table" then return model_id end
    local target = aliases[model_id]
    if type(target) == "string" and target ~= "" then return target end
    return model_id
end

function M.resolve(provider, model_id, models_dev)
    provider = provider or {}
    local namespace = declared_namespace(provider)
    local model_key = registry.canonical(alias_target(provider, model_id))
    if model_key == "" then
        return nil, "unknown", namespace
    end

    local override = override_for(provider, model_key)
    if override then
        return override, "provider_override", namespace
    end

    local rates = models_dev_for(models_dev, namespace, model_key)
    if rates then
        return rates, "models_dev", namespace
    end

    return nil, "unknown", namespace
end

function M.validate(rates)
    if rates == nil then return true end
    if rates.input == nil or rates.output == nil then
        return false, "pricing requires input and output rates"
    end
    return true
end

return M
