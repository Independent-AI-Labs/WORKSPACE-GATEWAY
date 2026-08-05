local M = {}

local MODES = {
    device_authorization = { suffix = "device-oauth", label = "Device OAuth" },
    authorization_code_pkce = { suffix = "browser-oauth", label = "Browser OAuth" },
    virtual_key = { suffix = "virtual-key", label = "Virtual Key" },
    api_key = { suffix = "api-key", label = "API Key" },
    none = { suffix = "no-auth", label = "No Auth" },
}

function M.mode(auth)
    if not auth then return MODES.none end
    if auth.type == "oauth" and auth.methods and auth.methods[1] then
        return MODES[auth.methods[1].flow] or MODES.oauth_device
    end
    return MODES[auth.flow] or MODES[auth.type] or MODES.none
end

function M.expected_id(provider, auth)
    return "workspace-gw-" .. provider.id .. "-" .. M.mode(auth).suffix
end

function M.expected_name(provider, auth)
    return "Workspace GW (" .. provider.label .. " " .. M.mode(auth).label .. ")"
end

function M.validate(provider)
    local auth = provider.auth or { type = "none" }
    local expected_id = M.expected_id(provider, auth)
    local expected_name = M.expected_name(provider, auth)
    return provider.id == expected_id and provider.name == expected_name,
        expected_id, expected_name
end

return M
