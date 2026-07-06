local core = require("apisix.core")
local cjson = require("cjson.safe")
local http = require("resty.http")

local plugin_name = "key-resolver"

local plugin = {
    version = 0.1,
    priority = 2555,
    name = plugin_name,
}

plugin.schema = {
    type = "object",
    properties = {
        openbao_addr = {
            type = "string",
            default = "http://openbao:8200",
        },
        openbao_token_env = {
            type = "string",
            default = "OPENBAO_TOKEN",
        },
        upstream_key_env = {
            type = "string",
            default = "OPENCODE_API_KEY",
        },
        key_prefix = {
            type = "string",
            default = "secret/data/gateway/keys/",
        },
        cache_ttl = {
            type = "integer",
            default = 300,
        },
        virtual_key_prefix = {
            type = "string",
            default = "vgw-",
        },
    },
}

function plugin.check_schema(conf)
    return core.schema.check(plugin.schema, conf)
end

local function extract_bearer(auth_header)
    if not auth_header then return nil end
    if type(auth_header) == "table" then
        auth_header = auth_header[1]
    end
    if not auth_header then return nil end
    return auth_header:match("^%s*[Bb]earer%s+(.+)%s*$")
end

local function fetch_key_from_openbao(conf, token)
    local openbao_token = os.getenv(conf.openbao_token_env)
    if not openbao_token or openbao_token == "" then
        return nil, "openbao token env var not set: " .. conf.openbao_token_env
    end

    local path = conf.key_prefix .. token
    local url = conf.openbao_addr .. "/v1/" .. path

    local httpc = http.new()
    local res, err = httpc:request_uri(url, {
        method = "GET",
        headers = {["X-Vault-Token"] = openbao_token},
        timeout = 3000,
        ssl_verify = false,
    })

    if not res then
        return nil, "openbao request failed: " .. (err or "unknown")
    end

    if res.status == 404 then
        return nil, "key not found in openbao"
    end

    if res.status ~= 200 then
        return nil, "openbao returned status " .. res.status .. ": " .. (res.body or "")
    end

    local body = cjson.decode(res.body)
    if not body then
        return nil, "openbao response json decode failed"
    end

    local data = body.data
    if not data or not data.data then
        return nil, "openbao response missing data.data"
    end

    return data.data, nil
end

local function resolve_key(conf, ctx, token)
    local shared = ngx.shared.key_cache
    if not shared then
        return nil, "key_cache shared dict not configured"
    end

    local cache_key = "k:" .. token
    local cached = shared:get(cache_key)
    if cached then
        local entry = cjson.decode(cached)
        if entry then
            return entry, nil
        end
    end

    local key_data, err = fetch_key_from_openbao(conf, token)
    if not key_data then
        return nil, err
    end

    local encoded = cjson.encode(key_data)
    if encoded then
        shared:set(cache_key, encoded, conf.cache_ttl)
    end

    return key_data, nil
end

function plugin.access(conf, ctx)
    local auth_header = core.request.header(ctx, "Authorization")
    if not auth_header then
        return 401, {error = "key-resolver: missing Authorization header"}
    end

    local token = extract_bearer(auth_header)
    if not token then
        return 401, {error = "key-resolver: invalid Authorization format"}
    end

    local vprefix = conf.virtual_key_prefix or "vgw-"

    if token:sub(1, #vprefix) ~= vprefix then
        ngx.req.set_header("Authorization", "Bearer " .. token)
        ngx.req.set_header("X-Gateway-Key-Id", "passthrough")
        ngx.req.set_header("X-Gateway-Tenant-Id", "direct")
        ngx.req.set_header("X-Gateway-User-Id", "")
        ctx.consumer = {
            username = "passthrough",
        }
        return
    end

    local key_data, err = resolve_key(conf, ctx, token)
    if not key_data then
        if err and err:find("not found") then
            return 401, {error = "key-resolver: invalid key"}
        end
        if err and err:find("not configured") then
            return 500, {error = "key-resolver: " .. err}
        end
        return 503, {error = "key-resolver: cannot reach key store: " .. (err or "unknown")}
    end

    if key_data.active == false then
        return 401, {error = "key-resolver: key revoked"}
    end

    local upstream_key = key_data.upstream_key
    if not upstream_key or upstream_key == "" then
        upstream_key = os.getenv(conf.upstream_key_env)
        if not upstream_key or upstream_key == "" then
            return 500, {error = "key-resolver: upstream key not configured"}
        end
    end

    ngx.req.set_header("Authorization", "Bearer " .. upstream_key)

    local key_id = key_data.virtual_key or token
    local tenant_id = key_data.tenant_id or "default"
    local user_id = key_data.user_id or ""

    ngx.req.set_header("X-Gateway-Key-Id", key_id)
    ngx.req.set_header("X-Gateway-Tenant-Id", tenant_id)
    ngx.req.set_header("X-Gateway-User-Id", user_id)

    ctx.consumer = {
        username = key_id,
    }
end

return plugin
