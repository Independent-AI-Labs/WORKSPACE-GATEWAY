local core = require("apisix.core")
local resty_sha256 = require("resty.sha256")

local plugin_name = "key-meta"

local plugin = {
    version = 0.1,
    priority = 2530,
    name = plugin_name,
}

plugin.schema = {
    type = "object",
    properties = {},
    additionalProperties = false,
}

function plugin.check_schema(conf)
    return core.schema.check(plugin.schema, conf)
end

local function hash_key(key)
    if key == nil or key == "" then return "" end
    local d = resty_sha256:new()
    d:update(key)
    local bin = d:final()
    local hex = {}
    for i = 1, #bin do
        hex[i] = string.format("%02x", string.byte(bin, i))
    end
    return table.concat(hex):sub(1, 16)
end

local function compute_hash()
    local auth_header = ngx.var.http_authorization
    local tok = ""
    if auth_header then
        local m = auth_header:match("^%s*[Bb]earer%s+(.+)%s*$")
        if m then tok = m end
    end

    local resolved = ngx.var.http_x_gateway_key_id or ""

    local final_key = resolved
    if (resolved == "" or resolved == "passthrough") and tok ~= "" then
        final_key = tok
    end

    return hash_key(final_key)
end

function plugin.access(conf, ctx)
    ngx.req.set_header("X-Key-Hash", compute_hash())
end

function plugin.log(conf, ctx)
    if ngx.var.http_x_key_hash == nil or ngx.var.http_x_key_hash == "" then
        ngx.req.set_header("X-Key-Hash", compute_hash())
    end
end

return plugin