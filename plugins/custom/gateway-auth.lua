local core = require("apisix.core")

local plugin_name = "gateway-auth"

local plugin = {
    version = 0.1,
    priority = 2555,
    name = plugin_name,
}

plugin.schema = {
    type = "object",
    properties = {
        mode = {
            type = "string",
            enum = { "inject", "passthrough" },
            default = "inject",
        },
        gateway_key = {
            type = "string",
        },
        upstream_key_env = {
            type = "string",
            default = "OPENCODE_ZEN_API_KEY",
        },
    },
    required = { "gateway_key" },
}

function plugin.check_schema(conf)
    return core.schema.check(plugin.schema, conf)
end

local function extract_bearer(auth_header)
    if not auth_header then return nil end
    if type(auth_header) == "table" then
        auth_header = auth_header[1]
    end
    local token = auth_header:match("^%s*[Bb]earer%s+(.+)%s*$")
    return token
end

function plugin.access(conf, ctx)
    if conf.mode == "inject" then
        local auth_header = core.request.header(ctx, "Authorization")
        if not auth_header then
            return 401, { error = "gateway-auth: missing Authorization header" }
        end
        local token = extract_bearer(auth_header)
        if not token then
            return 401, { error = "gateway-auth: invalid Authorization format" }
        end
        if token ~= conf.gateway_key then
            return 401, { error = "gateway-auth: invalid gateway key" }
        end
        local upstream_key = os.getenv(conf.upstream_key_env)
        if not upstream_key or upstream_key == "" then
            return 500, { error = "gateway-auth: upstream key not configured" }
        end
        ngx.req.set_header("Authorization", "Bearer " .. upstream_key)
    else
        local apikey = core.request.header(ctx, "apikey")
        if not apikey then
            return 401, { error = "gateway-auth: missing apikey header" }
        end
        if apikey ~= conf.gateway_key then
            return 401, { error = "gateway-auth: invalid gateway key" }
        end
        local auth_header = core.request.header(ctx, "Authorization")
        if not auth_header then
            return 401, { error = "gateway-auth: missing Authorization header" }
        end
        local token = extract_bearer(auth_header)
        if not token then
            return 401, { error = "gateway-auth: invalid Authorization format" }
        end
    end
end

return plugin
