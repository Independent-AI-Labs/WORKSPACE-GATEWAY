--plugins/custom/provider_sync_catalog.lua
--Internal catalog logic for provider-sync.
--Loaded by provider-sync.lua and tests as a plain Lua module.

local core = require("apisix.core")
local cjson = require("cjson.safe")

local M = {}

local SHARED_DICT = "gateway-cache"
local KEY_RAW = "providers:raw"
local KEY_ENRICHED = "providers:enriched"
local KEY_TS = "providers:ts"
local KEY_LOCK = "providers:lock"

local DEFAULT_PROVIDERS_DIR = "/usr/local/apisix/conf/providers"
local DEFAULT_MODELS_DEV_URL = "https://models.dev/api.json"
local DEFAULT_TTL = 3600
local DEFAULT_STALE = 86400
local DEFAULT_SYNC_TIMEOUT = 10000
local DEFAULT_WARMUP = true
local DEFAULT_BACKUP_LIMIT = 8192

local KIMI_USER_AGENT = "Kimi CLI (Linux 6.17.0-35-generic x64)"
local GENERIC_USER_AGENT = "WORKSPACE-GW/0.1"

M.DEFAULT_PROVIDERS_DIR = DEFAULT_PROVIDERS_DIR
M.DEFAULT_MODELS_DEV_URL = DEFAULT_MODELS_DEV_URL
M.DEFAULT_TTL = DEFAULT_TTL
M.DEFAULT_STALE = DEFAULT_STALE
M.DEFAULT_SYNC_TIMEOUT = DEFAULT_SYNC_TIMEOUT
M.DEFAULT_WARMUP = DEFAULT_WARMUP
M.DEFAULT_BACKUP_LIMIT = DEFAULT_BACKUP_LIMIT
M.KIMI_USER_AGENT = KIMI_USER_AGENT
M.GENERIC_USER_AGENT = GENERIC_USER_AGENT

local function ensure_deps_path()
    local deps_lua = "/usr/local/apisix/deps/share/lua/5.1"
    local deps_so = "/usr/local/apisix/deps/lib/lua/5.1"
    if not package.path:find(deps_lua, 1, true) then
        package.path = deps_lua .. "/?.lua;" .. deps_lua .. "/?/init.lua;" .. package.path
    end
    if not package.cpath:find(deps_so, 1, true) then
        package.cpath = deps_so .. "/?.so;" .. package.cpath
    end
end

local function get_lyaml()
    ensure_deps_path()
    local ok, lyaml = pcall(require, "lyaml")
    if not ok then
        return nil, lyaml
    end
    return lyaml, nil
end

local function get_dict()
    if not ngx or not ngx.shared then
        return nil
    end
    return ngx.shared[SHARED_DICT]
end

local function get_http()
    return require("resty.http")
end

local function read_file(path)
    local f, err = io.open(path, "r")
    if not f then
        return nil, err
    end
    local content = f:read("*a")
    f:close()
    return content, nil
end

local function list_yaml_files(dir)
    local files = {}
    local p = io.popen('ls -1 "' .. dir .. '"/*.yaml 2>/dev/null')
    if p then
        for line in p:lines() do
            table.insert(files, line)
        end
        p:close()
    end
    --Also include .yml files for flexibility.
    p = io.popen('ls -1 "' .. dir .. '"/*.yml 2>/dev/null')
    if p then
        for line in p:lines() do
            table.insert(files, line)
        end
        p:close()
    end
    return files
end

local function load_yaml(path)
    local lyaml, err = get_lyaml()
    if not lyaml then
        return nil, "lyaml not available: " .. (err or "unknown")
    end
    local content, read_err = read_file(path)
    if not content then
        return nil, "cannot read " .. path .. ": " .. (read_err or "unknown")
    end
    local ok, parsed = pcall(lyaml.load, content)
    if not ok then
        return nil, "yaml parse error in " .. path .. ": " .. tostring(parsed)
    end
    if type(parsed) ~= "table" then
        return nil, "yaml parse error in " .. path .. ": not a table"
    end
    return parsed, nil
end

local function load_providers(dir)
    local files = list_yaml_files(dir)
    local providers = {}
    for _, path in ipairs(files) do
        local provider, err = load_yaml(path)
        if provider then
            if provider.id then
                providers[provider.id] = provider
            else
                core.log.warn("provider_sync: skipping ", path, ": missing id")
            end
        else
            core.log.warn("provider_sync: failed to load ", path, ": ", err or "unknown")
        end
    end
    return providers
end

local function http_get(url, headers, timeout)
    local httpc = get_http().new()
    httpc:set_timeout(timeout or 10000)
    local res, err = httpc:request_uri(url, {
        method = "GET",
        headers = headers,
        ssl_verify = false,
    })
    if not res then
        return nil, "http request failed: " .. (err or "unknown")
    end
    if res.status ~= 200 then
        return nil, "http status " .. res.status
    end
    local body = res.body
    if not body or body == "" then
        return nil, "empty body"
    end
    local ok, parsed = pcall(cjson.decode, body)
    if not ok or type(parsed) ~= "table" then
        return nil, "json decode failed"
    end
    return parsed, nil
end

local function fetch_models_dev(url, timeout)
    local headers = {
        ["Accept"] = "application/json",
        ["User-Agent"] = KIMI_USER_AGENT,
    }
    return http_get(url, headers, timeout)
end

local function fetch_gateway_models(endpoint, api_key, timeout)
    local headers = {
        ["Accept"] = "application/json",
        ["User-Agent"] = GENERIC_USER_AGENT,
    }
    if api_key and api_key ~= "" then
        headers["Authorization"] = "Bearer " .. api_key
    end
    return http_get(endpoint, headers, timeout)
end

local function normalize_model_id(model_id, normalize)
    if not model_id or model_id == "" then
        return ""
    end
    local id = model_id
    if normalize and normalize.strip_prefix and normalize.strip_prefix ~= "" then
        local prefix = normalize.strip_prefix
        if id:sub(1, #prefix) == prefix then
            id = id:sub(#prefix + 1)
        end
    end
    if normalize and normalize.lowercase then
        id = id:lower()
    end
    return id
end

local function has_attachment(modalities)
    if not modalities or type(modalities) ~= "table" then
        return false
    end
    local input = modalities.input
    if not input or type(input) ~= "table" then
        return false
    end
    for _, v in ipairs(input) do
        if v == "image" or v == "video" then
            return true
        end
    end
    return false
end

local function scale_limit(context, pct, ceiling)
    local val = tonumber(context) or 0
    if val <= 0 then
        return 0
    end
    local scaled = math.floor(val * (tonumber(pct) or 100) / 100)
    if ceiling and tonumber(ceiling) and ceiling > 0 and scaled > ceiling then
        scaled = ceiling
    end
    return scaled
end

local function build_model_entry(model, model_id, normalize, pct, ceiling)
    local normalized_id = normalize_model_id(model_id, normalize)
    if normalized_id == "" then
        return nil
    end

    local entry = {
        name = model.name or normalized_id,
        reasoning = model.reasoning or false,
        attachment = model.attachment or has_attachment(model.modalities),
        tool_call = model.tool_call ~= false,
    }

    if model.limit then
        entry.limit = {
            context = scale_limit(model.limit.context, pct, ceiling),
            output = model.limit.output or DEFAULT_BACKUP_LIMIT,
        }
    end

    if model.cost then
        local cost = {
            input = model.cost.input or 0,
            output = model.cost.output or 0,
        }
        if model.cost.cache_read ~= nil then
            cost.cache_read = model.cost.cache_read
        end
        if model.cost.cache_write ~= nil then
            cost.cache_write = model.cost.cache_write
        end
        entry.cost = cost
    end

    return normalized_id, entry
end

local function build_models_from_models_dev(provider, models_dev)
    local source = provider.model_source
    local provider_name = source.provider
    local normalize = source.normalize
    local pct = provider.context_limit_pct or 100
    local ceiling = provider.context_limit_ceiling

    local models = {}
    if not models_dev or type(models_dev) ~= "table" then
        return models
    end

    local provider_block = models_dev[provider_name]
    if not provider_block or type(provider_block) ~= "table" or not provider_block.models then
        return models
    end

    for model_id, model in pairs(provider_block.models) do
        if type(model) == "table" then
            local nid, entry = build_model_entry(model, model_id, normalize, pct, ceiling)
            if nid and entry then
                models[nid] = entry
            end
        end
    end
    return models
end

local function extract_model_ids(data)
    local ids = {}
    if not data or type(data) ~= "table" then
        return ids
    end

    --OpenAI-compatible /models response: { data = [{ id = ... }] }
    if data.data and type(data.data) == "table" then
        for _, item in ipairs(data.data) do
            if type(item) == "table" and item.id then
                table.insert(ids, item.id)
            end
        end
        return ids
    end

    --Models.dev style: { provider = { models = { id = ... } } }
    --Extract IDs from the first provider block found.
    for _, provider in pairs(data) do
        if type(provider) == "table" and provider.models and type(provider.models) == "table" then
            for model_id, _ in pairs(provider.models) do
                table.insert(ids, model_id)
            end
            return ids
        end
    end

    return ids
end

local function build_models_from_endpoint(provider, data, backup_models)
    local pct = provider.context_limit_pct or 100
    local ceiling = provider.context_limit_ceiling
    local models = {}

    local backup_models_by_id = {}
    if backup_models and type(backup_models) == "table" then
        for _, f in ipairs(backup_models) do
            if f.id then
                backup_models_by_id[f.id] = f
            end
        end
    end

    local ids = extract_model_ids(data)
    if #ids == 0 and backup_models then
        for _, f in ipairs(backup_models) do
            if f.id then
                table.insert(ids, f.id)
            end
        end
    end

    for _, model_id in ipairs(ids) do
        local f = backup_models_by_id[model_id] or {}
        local entry = {
            name = f.name or model_id,
            reasoning = f.reasoning or false,
            attachment = f.attachment or false,
            tool_call = f.tool_call ~= false,
        }
        if f.limit then
            entry.limit = {
                context = scale_limit(f.limit.context, pct, ceiling),
                output = f.limit.output or DEFAULT_BACKUP_LIMIT,
            }
        end
        if f.cost then
            entry.cost = {
                input = f.cost.input or 0,
                output = f.cost.output or 0,
            }
            if f.cost.cache_read ~= nil then
                entry.cost.cache_read = f.cost.cache_read
            end
            if f.cost.cache_write ~= nil then
                entry.cost.cache_write = f.cost.cache_write
            end
        end
        models[model_id] = entry
    end

    return models
end

local function enrich_provider_models(provider, models_dev)
    local source = provider.model_source
    if not source or type(source) ~= "table" then
        return {}
    end

    local source_type = source.type
    if source_type == "models_dev_provider" then
        return build_models_from_models_dev(provider, models_dev)
    elseif source_type == "gateway" or source_type == "llamafile" then
        local endpoint = source.endpoint
        local api_key = source.api_key
        local backup_models = source.backup_models
        if endpoint then
            local full_url = endpoint
            if endpoint:sub(1, 1) == "/" then
                full_url = "http://localhost:9080" .. endpoint
            end
            local data, err = fetch_gateway_models(full_url, api_key, 10000)
            if data then
                return build_models_from_endpoint(provider, data, backup_models)
            else
                core.log.warn("provider_sync: failed to fetch models from ", full_url,
                              " for provider ", provider.id, ": ", err or "unknown")
            end
        end
        if backup_models then
            return build_models_from_endpoint(provider, {}, backup_models)
        end
        return {}
    else
        core.log.warn("provider_sync: unknown model_source type ", source_type,
                      " for provider ", provider.id)
        return {}
    end
end

local function populate_pricing_cache(enriched)
    local dict = get_dict()
    if not dict then
        return
    end
    for provider_id, provider in pairs(enriched) do
        if provider.models and type(provider.models) == "table" then
            for model_id, model in pairs(provider.models) do
                if model.cost then
                    local price = {
                        provider = provider_id,
                        input = model.cost.input or 0,
                        output = model.cost.output or 0,
                        cache_read = model.cost.cache_read or 0,
                        cache_write = model.cost.cache_write or 0,
                        fetched_at = ngx.time(),
                    }
                    dict:set("pricing:" .. model_id, cjson.encode(price), DEFAULT_STALE)
                end
            end
        end
    end
end

function M.sync(conf)
    local dict = get_dict()
    if not dict then
        return nil, "shared dict not found"
    end

    local lock_added = dict:add(KEY_LOCK, "1", 30)
    if not lock_added then
        return nil, "sync already in progress"
    end

    local providers = load_providers(conf.providers_dir)
    local models_dev, md_err = fetch_models_dev(conf.models_dev_url, conf.sync_timeout)
    if not models_dev then
        core.log.warn("provider_sync: models.dev fetch failed: ", md_err or "unknown")
    end

    local enriched = {}
    for provider_id, provider in pairs(providers) do
        local copy = cjson.decode(cjson.encode(provider)) or {}
        copy.models = enrich_provider_models(provider, models_dev)
        enriched[provider_id] = copy
    end

    dict:set(KEY_RAW, cjson.encode(providers), conf.stale_seconds)
    dict:set(KEY_ENRICHED, cjson.encode(enriched), conf.stale_seconds)
    dict:set(KEY_TS, tostring(ngx.time()), conf.stale_seconds)
    dict:delete(KEY_LOCK)

    populate_pricing_cache(enriched)

    return {
        providers_loaded = (function()
            local n = 0
            for _ in pairs(providers) do n = n + 1 end
            return n
        end)(),
        models_enriched = (function()
            local n = 0
            for _, p in pairs(enriched) do
                if p.models then
                    for _ in pairs(p.models) do n = n + 1 end
                end
            end
            return n
        end)(),
    }, nil
end

function M.get_enriched(conf)
    local dict = get_dict()
    if not dict then
        return nil, "shared dict not found"
    end

    local raw = dict:get(KEY_ENRICHED)
    if raw then
        return cjson.decode(raw), nil
    end

    local ts = dict:get(KEY_TS)
    if not ts then
        local ok, err = M.sync(conf)
        if not ok then
            return nil, err
        end
        raw = dict:get(KEY_ENRICHED)
        return cjson.decode(raw), nil
    end

    return nil, "cache miss"
end
return M
