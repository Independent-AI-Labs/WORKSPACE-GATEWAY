--plugins/custom/provider_sync_metadata.lua
--Pure helpers for provider_sync_catalog: models.dev metadata join, OpenCode
--model-entry construction, reasoning variants, and limit scaling. No ngx,
--shared-dict, or network access.
--
--Variant bodies mirror OpenCode's ProviderTransform.reasoningVariants /
--reasoningEffort (packages/opencode/src/provider/transform.ts). Only the
--effort case is implemented because budget_tokens and toggle are no-ops for
--the packages the gateway exposes (@ai-sdk/openai-compatible, @ai-sdk/openai).

local cjson = require("cjson.safe")

local M = {}

local DEFAULT_OUTPUT_LIMIT = 8192
local INCLUDE_ENCRYPTED_REASONING = "reasoning.encrypted_content"

local function has_attachment(modalities)
    if not modalities or type(modalities) ~= "table" then
        return false
    end
    local input = modalities.input
    if not input or type(input) ~= "table" then
        return false
    end
    for _, v in ipairs(input) do
        if v == "image" or v == "video" then
            return true
        end
    end
    return false
end

function M.scale_limit(context, pct, ceiling)
    local val = tonumber(context) or 0
    if val <= 0 then
        return 0
    end
    local scaled = math.floor(val * (tonumber(pct) or 100) / 100)
    if ceiling and tonumber(ceiling) and ceiling > 0 and scaled > ceiling then
        scaled = ceiling
    end
    return scaled
end

--FR-2.10: a known output limit never exceeds the exposed context.
function M.clamp_output(output, context)
    local out = tonumber(output) or DEFAULT_OUTPUT_LIMIT
    local ctx = tonumber(context) or 0
    if ctx > 0 and out > ctx then
        return ctx
    end
    return out
end

local function candidate_ids(model_id, normalize)
    local ids, seen = {}, {}
    local function add(value)
        if type(value) == "string" and value ~= "" and not seen[value] then
            seen[value] = true
            ids[#ids + 1] = value
        end
    end
    add(model_id)
    if normalize and normalize.strip_prefix and type(model_id) == "string" then
        add((model_id:gsub("^" .. normalize.strip_prefix, "")))
    end
    if type(model_id) == "string" then
        add(model_id:match("([^/]+)$"))
    end
    return ids
end

--Build a metadata lookup over one sync's models.dev snapshot for the
--declared namespace ONLY. There is no cross-provider index: an endpoint id
--must resolve inside the provider's own `pricing.source.provider` block.
function M.model_index(models_dev, provider_name)
    local declared = nil
    if provider_name and type(models_dev) == "table" then
        local block = models_dev[provider_name]
        if type(block) == "table" and type(block.models) == "table" then
            declared = block.models
        end
    end
    return { declared = declared }
end

function M.lookup(index, model_id, normalize)
    if not index or type(index.declared) ~= "table" then
        return nil
    end
    for _, id in ipairs(candidate_ids(model_id, normalize)) do
        if type(index.declared[id]) == "table" then
            return index.declared[id]
        end
    end
    return nil
end

--Overlay `extra` (static model_metadata / endpoint fields) over `base`
--(models.dev), with extra winning per present field.
function M.overlay(base, extra)
    if type(extra) ~= "table" or next(extra) == nil then
        return base
    end
    local merged = cjson.decode(cjson.encode(base or {})) or {}
    for k, v in pairs(extra) do
        if v ~= nil then
            merged[k] = v
        end
    end
    return merged
end

local function effort_body(npm, effort)
    if npm == "@ai-sdk/openai-compatible" then
        return { reasoningEffort = effort }
    end
    if npm == "@ai-sdk/openai" then
        return {
            reasoningEffort = effort,
            reasoningSummary = "auto",
            include = { INCLUDE_ENCRYPTED_REASONING },
        }
    end
    return nil
end

--FR-2.9: effort reasoning_options become OpenCode variant bodies. Returns nil
--(emit no `variants` key) when nothing maps.
function M.variants(reasoning_options, npm)
    if type(reasoning_options) ~= "table" then
        return nil
    end
    local effort
    for _, option in ipairs(reasoning_options) do
        if type(option) == "table" and option.type == "effort" then
            effort = option
            break
        end
    end
    if not effort or type(effort.values) ~= "table" then
        return nil
    end
    local variants = {}
    for _, value in ipairs(effort.values) do
        local id
        if value == nil or value == cjson.null then
            id = "none"
        elseif type(value) == "string" then
            id = value
        end
        if id and id ~= "" then
            local body = effort_body(npm, id)
            if body then
                variants[id] = body
            end
        end
    end
    if next(variants) == nil then
        return nil
    end
    return variants
end

--Shared entry builder for both model_source paths. `entry_id` is already
--normalized by the caller.
function M.build_entry(meta, entry_id, pct, ceiling, npm)
    meta = meta or {}
    local entry = {
        name = meta.name or entry_id,
        reasoning = meta.reasoning or false,
        attachment = meta.attachment or has_attachment(meta.modalities),
        tool_call = meta.tool_call ~= false,
    }

    if meta.family then entry.family = meta.family end
    if meta.release_date then entry.release_date = meta.release_date end
    if meta.temperature ~= nil then entry.temperature = meta.temperature end
    if meta.interleaved ~= nil then entry.interleaved = meta.interleaved end
    if type(meta.modalities) == "table" then
        entry.modalities = cjson.decode(cjson.encode(meta.modalities))
    end

    local variants = M.variants(meta.reasoning_options, npm)
    if variants then entry.variants = variants end

    if type(meta.limit) == "table" then
        local context = M.scale_limit(meta.limit.context, pct, ceiling)
        entry.limit = {
            context = context,
            output = M.clamp_output(meta.limit.output, context),
        }
    end

    --No cost here. Price is owned solely by provider_sync_pricing
    --(provider `pricing.overrides` or models.dev in the declared namespace);
    --a metadata/endpoint join must never carry a price.
    return entry
end

return M
