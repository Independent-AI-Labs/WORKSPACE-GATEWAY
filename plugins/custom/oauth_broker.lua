-- Shared gateway-side OAuth device-code generation.
local ok, jwt = pcall(require, "apisix.plugins.oauth_jwt")
if not ok then
    jwt = require("oauth_jwt")
end

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
