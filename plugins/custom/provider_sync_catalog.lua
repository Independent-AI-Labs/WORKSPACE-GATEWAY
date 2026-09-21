local core = require("apisix.core")
local cjson = require("cjson.safe")
local contract_ok, contract = pcall(require, "apisix.plugins.provider_sync_contract")
if not contract_ok then contract = require("provider_sync_contract") end
local aliases_ok, aliases = pcall(require, "apisix.plugins.provider_sync_aliases")
if not aliases_ok then aliases = require("provider_sync_aliases") end
local metadata_ok, metadata = pcall(require, "apisix.plugins.provider_sync_metadata")
if not metadata_ok then metadata = require("provider_sync_metadata") end
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
local KIMI_USER_AGENT = "Kimi CLI (Linux 6.17.0-35-generic x64)"
local GENERIC_USER_AGENT = "WORKSPACE-GW/0.1"
M.DEFAULT_PROVIDERS_DIR = DEFAULT_PROVIDERS_DIR
M.DEFAULT_MODELS_DEV_URL = DEFAULT_MODELS_DEV_URL
M.DEFAULT_TTL = DEFAULT_TTL
M.DEFAULT_STALE = DEFAULT_STALE
M.DEFAULT_SYNC_TIMEOUT = DEFAULT_SYNC_TIMEOUT
M.DEFAULT_WARMUP = DEFAULT_WARMUP

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
    if not f then return nil, err end
    local content = f:read("*a")
    f:close()
    return content, nil
end
local function list_yaml_files(dir)
    local files = {}
    for _, ext in ipairs({ "yaml", "yml" }) do
        local p = io.popen('ls -1 "' .. dir .. '"/*.' .. ext .. ' 2>/dev/null')
        if p then
            for line in p:lines() do files[#files + 1] = line end
            p:close()
        end
    end
    return files
end
local function load_yaml(path)
    local lyaml, err = get_lyaml()
    if not lyaml then return nil, "lyaml not available: " .. (err or "unknown") end
    local content, read_err = read_file(path)
    if not content then return nil, "cannot read " .. path .. ": " .. (read_err or "unknown") end
    local ok, parsed = pcall(lyaml.load, content)
    if not ok or type(parsed) ~= "table" then
        return nil, "yaml parse error in " .. path .. ": " .. tostring(parsed)
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
                if provider.provider then
                    local valid, expected_id, expected_name = contract.validate({
                        id = provider.id,
                        name = provider.name,
                        label = provider.provider.label,
                        auth = provider.auth,
                    })
                    if not valid then
                        core.log.warn("provider_sync: naming mismatch for ", provider.id,
                            "; expected ", expected_id, " / ", expected_name)
                    end
                end
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
            local nid = normalize_model_id(model_id, normalize)
            if nid ~= "" then
                models[nid] = metadata.build_entry(model, nid, pct, ceiling, provider.npm)
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

    if data.data and type(data.data) == "table" then
        for _, item in ipairs(data.data) do
            if type(item) == "table" and item.id then ids[#ids + 1] = item.id end
        end
        return ids
    end

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
local function build_models_from_endpoint(provider, data, model_metadata, models_dev, source_provider)
    local pct = provider.context_limit_pct or 100
    local ceiling = provider.context_limit_ceiling
    local normalize = provider.model_source and provider.model_source.normalize
    local models = {}

    local metadata_by_id = {}
    if model_metadata and type(model_metadata) == "table" then
        for _, f in ipairs(model_metadata) do
            if f.id then
                metadata_by_id[f.id] = f
            end
        end
    end

    local index = metadata.model_index(models_dev, source_provider)
    local ids = extract_model_ids(data)

    for _, model_id in ipairs(ids) do
        local base = metadata.lookup(index, model_id, normalize)
        local merged = metadata.overlay(base, metadata_by_id[model_id])
        models[model_id] = metadata.build_entry(merged, model_id, pct, ceiling, provider.npm)
    end

    return models
end
local function matches_any(model_id, patterns)
    if type(patterns) ~= "table" then return false end
    for _, pat in ipairs(patterns) do
        if pat and pat ~= "" and string.find(model_id, pat) then return true end
    end
    return false
end
local function apply_model_filter(models, filter)
    if not filter or type(filter) ~= "table" then
        return models
    end
    local include = filter.include
    local has_include = include and type(include) == "table" and next(include) ~= nil
    local filtered = {}
    for model_id, entry in pairs(models) do
        if not matches_any(model_id, filter.exclude)
           and (not has_include or matches_any(model_id, include)) then
            filtered[model_id] = entry
        end
    end
    return filtered
end
local function enrich_provider_models(provider, models_dev)
    local source = provider.model_source
    if not source or type(source) ~= "table" then
        return {}
    end

    local models
    local source_type = source.type
    if source_type == "models_dev_provider" then
        models = build_models_from_models_dev(provider, models_dev)
    elseif source_type == "gateway" or source_type == "llamafile" then
        local endpoint = source.endpoint
        local api_key = source.api_key
        local model_metadata = source.model_metadata
        if not endpoint then
            core.log.error("provider_sync: provider ", provider.id,
                           " has source type ", source_type, " but no endpoint")
            return {}
        end
        local full_url = endpoint
        if endpoint:sub(1, 1) == "/" then
            full_url = "http://localhost:9080" .. endpoint
        end
        local data, err = fetch_gateway_models(full_url, api_key, 10000)
        if not data then
            core.log.error("provider_sync: failed to fetch models from ", full_url,
                           " for provider ", provider.id, ": ", err or "unknown",
                           "; provider will sync with zero models")
            return {}
        end
        local source_provider = provider.cost_source
        if provider.pricing and provider.pricing.source then
            source_provider = provider.pricing.source.provider or source_provider
        end
        if source.provider then
            source_provider = source.provider
        end
        models = build_models_from_endpoint(provider, data, model_metadata,
            models_dev, source_provider)
        if not next(models) then
            core.log.error("provider_sync: endpoint ", full_url,
                           " for provider ", provider.id,
                           " returned zero model ids; provider will sync with zero models")
        end
    else
        core.log.warn("provider_sync: unknown model_source type ", source_type,
                      " for provider ", provider.id)
        return {}
    end

    return apply_model_filter(models, source.filter)
end
local pricing
do
    local ok, mod = pcall(require, "apisix.plugins.provider_sync_pricing")
    if ok then
        pricing = mod
    else
        pricing = require("provider_sync_pricing")
    end
end

function M.sync(conf)
    local dict = get_dict()
    if not dict then
        return nil, "shared dict not found"
    end

    conf = conf or {}
    local providers_dir = conf.providers_dir or DEFAULT_PROVIDERS_DIR
    local models_dev_url = conf.models_dev_url or DEFAULT_MODELS_DEV_URL
    local sync_timeout = conf.sync_timeout or DEFAULT_SYNC_TIMEOUT
    local stale_seconds = conf.stale_seconds or DEFAULT_STALE

    local lock_added = dict:add(KEY_LOCK, "1", 30)
    if not lock_added then
        return nil, "sync already in progress"
    end

    local providers = load_providers(providers_dir)
    local models_dev, md_err = fetch_models_dev(models_dev_url, sync_timeout)
    if not models_dev then
        core.log.warn("provider_sync: models.dev fetch failed: ", md_err or "unknown")
    end

    local enriched = {}
    for provider_id, provider in pairs(providers) do
        local copy = cjson.decode(cjson.encode(provider)) or {}
        copy.models = enrich_provider_models(provider, models_dev)
        aliases.expand(provider, copy.models)
        pricing.apply_cost_source(provider, copy.models, models_dev)
        enriched[provider_id] = copy
    end

    dict:set(KEY_RAW, cjson.encode(providers), stale_seconds)
    dict:set(KEY_ENRICHED, cjson.encode(enriched), stale_seconds)
    dict:set(KEY_TS, tostring(ngx.time()), stale_seconds)
    dict:delete(KEY_LOCK)

    pricing.populate_pricing_cache(enriched)

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
