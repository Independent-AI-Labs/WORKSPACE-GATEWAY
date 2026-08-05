local cjson = require("cjson.safe")

local M = {}

local function alias_display_name(alias_id)
    local name = alias_id:gsub("[_%-]+", " ")
    return name:gsub("(%a)([%w]*)", function(first, rest)
        return first:upper() .. rest
    end)
end

function M.expand(provider, models)
    local aliases = provider.model_aliases
    if not aliases or type(aliases) ~= "table" then
        return models
    end

    for alias_id, target_id in pairs(aliases) do
        local model = models[target_id]
        if model then
            local alias_model = cjson.decode(cjson.encode(model))
            alias_model.name = alias_display_name(alias_id)
            models[alias_id] = alias_model
        end
    end
    return models
end

return M
