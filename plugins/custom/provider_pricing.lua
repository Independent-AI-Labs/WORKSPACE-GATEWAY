-- Shared pricing source resolution for provider catalog generation.
-- This module is pure: it does not access ngx, shared dictionaries, or the
-- network. Callers provide the provider definition and models.dev snapshot.

local M = {}

local function number_or_nil(value)
    if value == nil then return nil end
    local number = tonumber(value)
    if not number or number < 0 then return nil end
    return number
end

local function copy_rates(source)
    if type(source) ~= "table" then return nil end
    local rates = {}
    for _, field in ipairs({
        "input", "output", "reasoning", "cache_read", "cache_write",
        "input_audio", "output_audio",
    }) do
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

local function merge_rates(target, source)
    local copied = copy_rates(source)
    if not copied then return target end
    target = target or {}
    for key, value in pairs(copied) do
        if target[key] == nil then target[key] = value end
    end
    return target
end

local function candidate_ids(provider, model_id)
    local ids = {}
    local seen = {}
    local function add(value)
        if type(value) == "string" and value ~= "" and not seen[value] then
            seen[value] = true
            table.insert(ids, value)
        end
    end
    add(model_id)
    local normalize = (provider.catalog and provider.catalog.normalize)
        or (provider.model_source and provider.model_source.normalize)
    if normalize and normalize.strip_prefix and type(model_id) == "string" then
        add((model_id:gsub("^" .. normalize.strip_prefix, "")))
    end
    if type(model_id) == "string" then
        add(model_id:match("([^/]+)$"))
    end
    return ids
end

local function find_models_dev(models_dev, source_provider, provider, model_id)
    if type(models_dev) ~= "table" or not source_provider then return nil end
    local block = models_dev[source_provider]
    if type(block) ~= "table" or type(block.models) ~= "table" then return nil end
    for _, id in ipairs(candidate_ids(provider, model_id)) do
        if type(block.models[id]) == "table" then return block.models[id] end
    end
    return nil
end

function M.resolve(provider, model_id, discovered_model, models_dev)
    provider = provider or {}
    local pricing = provider.pricing or {}
    local source = pricing.source or {}
    local metadata = provider.catalog and provider.catalog.metadata or {}
    local rates
    local provenance = "unknown"
    local source_provider

    local override = pricing.overrides and pricing.overrides[model_id]
    rates = merge_rates(rates, override)
    if rates then provenance = "provider_override" end

    if source.type == "models_dev" or source.type == "models_dev_provider" then
        source_provider = source.provider
    elseif source.type == nil and metadata.source == "models_dev" then
        source_provider = metadata.provider
    elseif source.type == nil and provider.model_source
        and provider.model_source.type == "models_dev_provider" then
        source_provider = provider.model_source.provider
    end
    if not source_provider and provider.cost_source then
        source_provider = provider.cost_source
    end

    local models_dev_model = find_models_dev(models_dev, source_provider, provider, model_id)
    local models_dev_rates = copy_rates(models_dev_model and models_dev_model.cost)
    if models_dev_rates then
        rates = merge_rates(rates, models_dev_rates)
        if provenance == "unknown" then provenance = "models_dev" end
    end

    rates = merge_rates(rates, discovered_model and discovered_model.cost)
    if rates and provenance == "unknown" then provenance = "static_or_endpoint" end

    if source.type == "unknown" or pricing.missing_policy == "unknown" then
        return rates, provenance, source_provider
    end
    return rates, provenance, source_provider
end

function M.validate(rates)
    if rates == nil then return true end
    if rates.input == nil or rates.output == nil then
        return false, "pricing requires input and output rates"
    end
    return true
end

return M
