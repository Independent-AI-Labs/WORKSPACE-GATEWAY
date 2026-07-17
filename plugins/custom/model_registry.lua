-- GENERATED FILE - DO NOT EDIT.
-- Source: conf/model-registry.yaml
-- Regenerate: res/scripts/gen-model-registry.sh
-- Single source of truth for model canonicalization. Used by
-- cost_calc.lua, sse-usage.lua and provider_sync_catalog.lua.
local M = {}

local alias_map = {
    ["/zip/minicpm5-1b-q8_0.gguf"] = "minicpm5-1b-q8_0.gguf",
    ["accounts/fireworks/models/glm-5p0"] = "glm-5",
    ["accounts/fireworks/models/glm-5p1"] = "glm-5.1",
    ["accounts/fireworks/models/glm-5p2"] = "glm-5.2",
    ["frank/glm-5.2"] = "glm-5.2",
    ["glm-5"] = "glm-5",
    ["glm-5.1"] = "glm-5.1",
    ["glm-5.2"] = "glm-5.2",
    ["glm-5p0"] = "glm-5",
    ["glm-5p1"] = "glm-5.1",
    ["glm-5p2"] = "glm-5.2",
    ["k3"] = "kimi-k2.7-code",
    ["kimi-for-coding"] = "kimi-k2.7-code",
    ["kimi-k2.7-code"] = "kimi-k2.7-code",
    ["minicpm5-1b-q8_0.gguf"] = "minicpm5-1b-q8_0.gguf",
    ["moonshotai/kimi-k2.7-code"] = "kimi-k2.7-code",
    ["z-ai/glm-5"] = "glm-5",
    ["z-ai/glm-5.1"] = "glm-5.1",
    ["z-ai/glm-5.2"] = "glm-5.2",
}
M.alias_map = alias_map

local function last_segment(id)
    local slash = id:reverse():find("/", 1, true)
    if slash then
        return id:sub(#id - slash + 2)
    end
    return id
end
M.last_segment = last_segment

--Canonicalize any observed model string (request body or upstream echo)
--to its models.dev-style canonical id:
--  1. lowercase, exact alias-map hit (covers full paths like
--     "accounts/fireworks/models/glm-5p2" and "frank/glm-5.2")
--  2. last "/" segment alias-map hit (covers "provider/alias" forms)
--  3. otherwise the lowercased last segment (unknown models pass through
--     unchanged so new models never break logging)
function M.canonical(name)
    if not name or name == "" then
        return ""
    end
    local lower = tostring(name):lower()
    local hit = alias_map[lower]
    if hit then
        return hit
    end
    local seg = last_segment(lower)
    return alias_map[seg] or seg
end

function M.is_canonical(id)
    return alias_map[id] == id
end

return M
