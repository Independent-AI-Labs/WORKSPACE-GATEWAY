local core = require("apisix.core")
local cjson = require("cjson.safe")
local http = require("resty.http")
local pool_lib = require("apisix.plugins.upstream_pool_lib")

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
        pool_prefix = {
            type = "string",
            default = "secret/data/gateway/upstream-pools/",
        },
        cache_ttl = {
            type = "integer",
            default = 300,
        },
        virtual_key_prefix = {
            type = "string",
            default = "vgw-",
        },
        default_rate_limit_rpm = {
            type = "integer",
            default = 100,
        },
        default_rate_limit_window = {
            type = "integer",
            default = 60,
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

local function openbao_get(conf, path)
    local openbao_token = os.getenv(conf.openbao_token_env)
    if not openbao_token or openbao_token == "" then
        return nil, "openbao token env var not set: " .. conf.openbao_token_env
    end

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
        return nil, "not found in openbao: " .. path
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

local function openbao_put(conf, path, record)
    local openbao_token = os.getenv(conf.openbao_token_env)
    if not openbao_token or openbao_token == "" then
        return "openbao token env var not set: " .. conf.openbao_token_env
    end

    local url = conf.openbao_addr .. "/v1/" .. path
    local payload = cjson.encode({data = record})
    if not payload then
        return "openbao payload encode failed"
    end

    local httpc = http.new()
    local res, err = httpc:request_uri(url, {
        method = "POST",
        headers = {["X-Vault-Token"] = openbao_token, ["Content-Type"] = "application/json"},
        body = payload,
        timeout = 3000,
        ssl_verify = false,
    })

    if not res then
        return "openbao request failed: " .. (err or "unknown")
    end

    if res.status < 200 or res.status >= 300 then
        return "openbao write returned status " .. res.status .. ": " .. (res.body or "")
    end

    return nil
end

local function fetch_key_from_openbao(conf, token)
    return openbao_get(conf, conf.key_prefix .. token)
end

local function resolve_pool(conf, pool_name)
    local shared = ngx.shared.key_cache
    if not shared then
        return nil, "key_cache shared dict not configured"
    end

    local cache_key = "p:" .. pool_name
    local cached = shared:get(cache_key)
    if cached then
        local entry = cjson.decode(cached)
        if entry then
            return entry, nil
        end
    end

    local pool_data, err = openbao_get(conf, (conf.pool_prefix or "secret/data/gateway/upstream-pools/") .. pool_name)
    if not pool_data then
        return nil, err
    end

    local encoded = cjson.encode(pool_data)
    if encoded then
        shared:set(cache_key, encoded, conf.cache_ttl)
    end

    return pool_data, nil
end

local function pool_key_unavailable(pool_state, marker_prefix, key_id)
    if not pool_state then
        return false
    end
    if pool_state:get("dis:" .. marker_prefix .. ":" .. key_id) then
        return true
    end
    if pool_state:get("cd:" .. marker_prefix .. ":" .. key_id) then
        return true
    end
    return false
end

local function disable_pool_key_in_openbao(premature, conf, pool_name, key_id)
    if premature then
        return
    end
    local prefix = conf.pool_prefix or "secret/data/gateway/upstream-pools/"
    local pool, err = openbao_get(conf, prefix .. pool_name)
    if not pool then
        core.log.error("key-resolver: pool disable fetch failed for ", pool_name, ": ", err)
        return
    end
    local updated, merr = pool_lib.mark_disabled(pool, key_id)
    if not updated then
        core.log.error("key-resolver: pool disable mark failed for ", pool_name, "/", key_id, ": ", merr)
        return
    end
    local werr = openbao_put(conf, prefix .. pool_name, updated)
    if werr then
        core.log.error("key-resolver: pool disable write failed for ", pool_name, ": ", werr)
        return
    end
    local shared = ngx.shared.key_cache
    if shared then
        shared:delete("p:" .. pool_name)
    end
    core.log.warn("key-resolver: pool key disabled in openbao: ", pool_name, "/", key_id)
end

local function select_pool_key(conf, ctx, pool_name)
    local pool, err = resolve_pool(conf, pool_name)
    if not pool then
        return nil, "pool fetch failed: " .. (err or "unknown"), 503
    end

    local pool_state = ngx.shared.pool_state
    if not pool_state then
        core.log.error("key-resolver: pool_state shared dict not configured")
    end

    --- Pool epoch (bumped on every management write) namespaces the in-memory
    --- markers so `pool-key.sh reset` re-enabled keys are not shadowed by
    --- stale per-worker disable markers.
    local epoch = tonumber(pool.epoch) or 0
    local marker_prefix = pool_name .. ":" .. epoch

    local entry, serr = pool_lib.select_sticky(pool, function(key_id)
        return pool_key_unavailable(pool_state, marker_prefix, key_id)
    end)
    if not entry then
        return nil, "upstream pool '" .. pool_name .. "' exhausted (" .. (serr or "no available keys")
            .. ") - rotated keys are cooling down or disabled, retry later", 503
    end

    ctx.upstream_pool_name = pool_name
    ctx.upstream_pool_marker_prefix = marker_prefix
    ctx.upstream_pool_key_id = entry.id
    return entry.key, nil, nil
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
        ngx.req.set_header("X-Gateway-Rate-Limit-RPM", tostring(conf.default_rate_limit_rpm))
        ngx.req.set_header("X-Gateway-Rate-Limit-Window", tostring(conf.default_rate_limit_window))
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

    local upstream_key
    local pool_name = key_data.upstream_pool
    if pool_name and pool_name ~= "" then
        local k, perr, pstatus = select_pool_key(conf, ctx, pool_name)
        if not k then
            return pstatus or 503, {error = "key-resolver: " .. (perr or "pool unavailable")}
        end
        upstream_key = k
    else
        upstream_key = key_data.upstream_key
        if not upstream_key or upstream_key == "" then
            upstream_key = os.getenv(conf.upstream_key_env)
            if not upstream_key or upstream_key == "" then
                return 500, {error = "key-resolver: upstream key not configured"}
            end
        end
    end

    ngx.req.set_header("Authorization", "Bearer " .. upstream_key)

    local key_id = key_data.virtual_key or token
    local tenant_id = key_data.tenant_id or "default"
    local user_id = key_data.user_id or ""

    ngx.req.set_header("X-Gateway-Key-Id", key_id)
    ngx.req.set_header("X-Gateway-Tenant-Id", tenant_id)
    ngx.req.set_header("X-Gateway-User-Id", user_id)

    --- Per-key RPM limits (Tier 2)
    local rpm = key_data.rate_limit_rpm or conf.default_rate_limit_rpm
    local rpm_window = key_data.rate_limit_window or conf.default_rate_limit_window
    ngx.req.set_header("X-Gateway-Rate-Limit-RPM", tostring(rpm))
    ngx.req.set_header("X-Gateway-Rate-Limit-Window", tostring(rpm_window))

    --- Per-key token/cost budget enforcement via shared dict (Tier 3)
    local token_budget = tonumber(key_data.token_budget) or 0
    local cost_budget = tonumber(key_data.cost_budget) or 0
    local budget_window = tonumber(key_data.budget_window) or 86400
    local budget_type = key_data.budget_type or "tokens"

    if token_budget > 0 or cost_budget > 0 then
        local qd = ngx.shared.quota_counters
        if qd then
            local now = ngx.time()
            local ws = math.floor(now / budget_window) * budget_window
            local bucket_key = "q:" .. key_id .. ":" .. tostring(ws)
            local spent = qd:get(bucket_key) or 0

            local budget = cost_budget > 0 and cost_budget or token_budget
            local actual_type = cost_budget > 0 and "cost" or "tokens"

            ctx.quota_bucket_key = bucket_key
            ctx.quota_budget = budget
            ctx.quota_window = budget_window
            ctx.quota_type = actual_type
            ctx.quota_spent = spent

            if spent >= budget then
                return 429, {error = "key-resolver: quota exceeded - " .. actual_type .. " budget depleted for this key"}
            end
        else
            core.log.error("key-resolver: quota_counters shared dict not configured")
        end
    end

    ctx.consumer = {
        username = key_id,
    }
end

function plugin.header_filter(conf, ctx)
    local pool_name = ctx.upstream_pool_name
    local key_id = ctx.upstream_pool_key_id
    local marker_prefix = ctx.upstream_pool_marker_prefix or pool_name
    if not pool_name or not key_id then
        return
    end

    local status = ngx.status
    local pool_state = ngx.shared.pool_state
    if not pool_state then
        return
    end

    --- Pool record is read from the cache populated during access (no network
    --- I/O in header_filter). On cache miss, fall back to pool defaults.
    local pool
    local shared = ngx.shared.key_cache
    if shared then
        local cached = shared:get("p:" .. pool_name)
        if cached then
            pool = cjson.decode(cached)
        end
    end

    if pool_lib.status_in(pool_lib.disable_on(pool), status) then
        pool_state:set("dis:" .. marker_prefix .. ":" .. key_id, 1)
        ngx.header["X-Gateway-Upstream-Rotated"] = "disabled:" .. key_id
        core.log.warn("key-resolver: upstream key hard-disabled (status ", status, "): ",
            pool_name, "/", key_id)
        local ok, err = ngx.timer.at(0, disable_pool_key_in_openbao, conf, pool_name, key_id)
        if not ok then
            core.log.error("key-resolver: failed to schedule pool disable write: ", err)
        end
    elseif pool_lib.status_in(pool_lib.cooldown_on(pool), status) then
        local cooldown_s = pool_lib.cooldown_s(pool)
        pool_state:set("cd:" .. marker_prefix .. ":" .. key_id, 1, cooldown_s)
        ngx.header["X-Gateway-Upstream-Rotated"] = "cooldown:" .. key_id
        core.log.warn("key-resolver: upstream key cooling down ", cooldown_s, "s (status ",
            status, "): ", pool_name, "/", key_id)
    end
end

return plugin
