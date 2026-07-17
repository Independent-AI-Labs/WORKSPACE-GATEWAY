--plugins/custom/provider-sync.lua
--Gateway-managed provider catalog and client config service.
--
--Reads static provider definitions from conf/providers/*.yaml, enriches them
--with model metadata and pricing from models.dev or provider endpoints, and
--exposes read-only HTTP endpoints for OpenCode clients.
--
--Required as: require("apisix.plugins.provider-sync")

local core = require("apisix.core")
local cjson = require("cjson.safe")
local catalog = require("provider_sync_catalog")

local plugin_name = "provider-sync"

local plugin = {
    version = 0.1,
    priority = 2570,
    name = plugin_name,
}

local M = plugin
plugin.schema = {
    type = "object",
    properties = {
        providers_dir = {
            type = "string",
            default = catalog.DEFAULT_PROVIDERS_DIR,
        },
        models_dev_url = {
            type = "string",
            default = catalog.DEFAULT_MODELS_DEV_URL,
        },
        ttl_seconds = {
            type = "integer",
            default = catalog.DEFAULT_TTL,
        },
        stale_seconds = {
            type = "integer",
            default = catalog.DEFAULT_STALE,
        },
        sync_timeout = {
            type = "integer",
            default = catalog.DEFAULT_SYNC_TIMEOUT,
        },
        warmup_on_init = {
            type = "boolean",
            default = catalog.DEFAULT_WARMUP,
        },
    },
}

function plugin.check_schema(conf)
    return core.schema.check(plugin.schema, conf)
end

local function get_gateway_base(ctx)
    local scheme = ngx.var.scheme or "http"
    local host = ngx.var.host or "localhost"
    local port = ngx.var.server_port
    local base = scheme .. "://" .. host
    if port and port ~= "" and port ~= "80" and port ~= "443" then
        base = base .. ":" .. port
    end
    return base
end

local function build_opencode_block(provider, gateway_base)
    local base_url = gateway_base .. provider.route
    local options = {
        baseURL = base_url,
    }
    if provider.options and provider.options.headers and type(provider.options.headers) == "table" then
        options.headers = {}
        for k, v in pairs(provider.options.headers) do
            options.headers[k] = v
        end
    end

    local auth_route = nil
    if provider.auth and provider.auth.type == "oauth" then
        auth_route = provider.route .. "/auth"
    end

    return {
        provider_id = provider.id,
        provider = {
            name = provider.name,
            npm = provider.npm,
            options = options,
            models = provider.models or {},
        },
        auth_type = provider.auth and provider.auth.type or "none",
        auth_route = auth_route,
        metadata = provider.metadata or {},
    }
end

local function list_providers(enriched)
    local list = {}
    for id, provider in pairs(enriched or {}) do
        table.insert(list, {
            id = id,
            name = provider.name or id,
            auth_type = provider.auth and provider.auth.type or "none",
        })
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

local function json_response(status, body)
    core.response.set_header("Content-Type", "application/json")
    core.response.exit(status, cjson.encode(body))
end

function plugin.init()
    --APISIX calls plugin.init() during initialization. Warm up the cache
    --in the background so the first client request is fast.
    if not ngx or not ngx.timer then
        return
    end
    local default_conf = {}
    for k, v in pairs(plugin.schema.properties) do
        default_conf[k] = v.default
    end
    local ok, err = ngx.timer.at(0, function(premature)
        if premature then
            return
        end
        M.sync(default_conf)
    end)
    if not ok then
        core.log.warn("provider_sync: failed to spawn warmup timer: ", err or "unknown")
    end
end

function plugin.access(conf, ctx)
    local uri = ctx.var.uri or ""

    --POST /gateway/providers/sync
    if uri == "/gateway/providers/sync" then
        local result, err = M.sync(conf)
        if result then
            return json_response(200, {
                ok = true,
                providers_loaded = result.providers_loaded,
                models_enriched = result.models_enriched,
            })
        elseif err == "sync already in progress" then
            return json_response(202, { ok = true, status = "sync already in progress" })
        else
            core.log.error("provider_sync: sync failed: ", err or "unknown")
            return json_response(503, { error = "sync failed", details = err or "unknown" })
        end
    end

    local enriched, err = M.get_enriched(conf)
    if not enriched then
        core.log.error("provider_sync: cannot load enriched catalog: ", err or "unknown")
        return json_response(503, { error = "provider catalog unavailable", details = err or "unknown" })
    end

    --GET /gateway/providers
    if uri == "/gateway/providers" then
        return json_response(200, list_providers(enriched))
    end

    --GET /gateway/providers/{id}
    local id_only = uri:match("^/gateway/providers/([^/]+)$")
    if id_only then
        local provider = enriched[id_only]
        if not provider then
            return json_response(404, { error = "provider not found" })
        end
        return json_response(200, provider)
    end

    --GET /gateway/providers/{id}/opencode
    local id_opencode = uri:match("^/gateway/providers/([^/]+)/opencode$")
    if id_opencode then
        local provider = enriched[id_opencode]
        if not provider then
            return json_response(404, { error = "provider not found" })
        end
        local gateway_base = get_gateway_base(ctx)
        return json_response(200, build_opencode_block(provider, gateway_base))
    end

    return json_response(404, { error = "not found" })
end

M.sync = catalog.sync
M.get_enriched = catalog.get_enriched
return plugin
