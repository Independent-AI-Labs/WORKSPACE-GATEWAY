-- Shared gateway-side OAuth device-code generation.
local jwt = require("apisix.plugins.oauth_jwt")

local M = {}

function M.gateway_device_code(upstream_code)
    local request_id = ""
    pcall(function() request_id = ngx.var.request_id or "" end)
    local material = table.concat({
        upstream_code,
        request_id,
        tostring(ngx.now()),
        tostring(math.random()),
    }, ":")
    return "gw-" .. jwt.token_hash(material)
end

return M
