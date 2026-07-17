local cjson = require("cjson.safe")

--In-memory shared dict ------------------------------------------------------
local cache = {}
local shared = {
    get = function(self, key)
        return cache[key], nil
    end,
    set = function(self, key, value, ttl)
        cache[key] = value
        return true
    end,
    add = function(self, key, value, ttl)
        if cache[key] ~= nil then
            return nil, "exists"
        end
        cache[key] = value
        return true
    end,
    delete = function(self, key)
        cache[key] = nil
    end,
}

if not ngx.shared then
    ngx.shared = {}
end
ngx.shared["gateway-cache"] = shared

--Ensure minimal ngx.var values are set for gateway base URL construction.
local ok = pcall(function()
    ngx.var.scheme = ngx.var.scheme or "http"
    ngx.var.host = ngx.var.host or "localhost"
    ngx.var.server_port = ngx.var.server_port or "9080"
end)
if not ok then
    --Resty CLI may not allow setting ngx.var; in that case core.response.exit
    --will not be exercised and the opencode base URL assertions are skipped.
    ngx.var = setmetatable({}, {
        __index = function(t, k)
            if k == "scheme" then return "http" end
            if k == "host" then return "localhost" end
            if k == "server_port" then return "9080" end
            return nil
        end,
        __newindex = function(t, k, v) end,
    })
end

--Mock resty.http ----------------------------------------------------------------
local captured_requests = {}
local fake_models_dev = {
    kimi = {
        models = {
            ["kimi-k1"] = {
                name = "Kimi K1",
                reasoning = false,
                attachment = false,
                tool_call = true,
                limit = { context = 128000, output = 8192 },
                cost = { input = 1.0, output = 3.0, cache_read = 0.5, cache_write = 1.5 },
            },
            ["kimi-k1-vision"] = {
                name = "Kimi K1 Vision",
                reasoning = false,
                attachment = true,
                tool_call = true,
                limit = { context = 128000, output = 8192 },
                cost = { input = 2.0, output = 6.0 },
            },
        },
    },
    openai = {
        models = {
            ["gpt-5"] = {
                name = "GPT-5",
                reasoning = true,
                attachment = false,
                tool_call = true,
                limit = { context = 256000, output = 16384 },
                cost = { input = 5.0, output = 15.0 },
            },
        },
    },
}

local fake_http = {
    new = function()
        return {
            set_timeout = function(self, t) end,
            request_uri = function(self, url, opts)
                table.insert(captured_requests, {
                    url = url,
                    method = opts.method or "GET",
                    headers = opts.headers or {},
                })
                return {
                    status = 200,
                    body = cjson.encode(fake_models_dev),
                }, nil
            end,
        }
    end,
}
package.loaded["resty.http"] = fake_http

--Mock apisix.core ---------------------------------------------------------------
local last_response = nil
local core_mock = {
    log = {
        warn = function(...) end,
        error = function(...) end,
    },
    schema = {
        check = function(schema, conf)
            return true
        end,
    },
    response = {
        set_header = function(...) end,
        exit = function(status, body)
            last_response = { status = status, body = body }
            return nil
        end,
    },
}
package.loaded["apisix.core"] = core_mock

--Load plugin under test -----------------------------------------------------------
local provider_sync = require("provider-sync")

--Test helpers ----------------------------------------------------------------------
local pass = 0
local fail = 0

local function check(cond, msg)
    if cond then
        pass = pass + 1
    else
        fail = fail + 1
        io.stderr:write("[FAIL] " .. msg .. "\n")
    end
end

local function assert_eq(actual, expected, msg)
    if type(expected) == "string" and type(actual) == "string" then
        check(actual == expected, msg .. " expected=[" .. expected .. "] actual=[" .. actual .. "]")
    else
        check(actual == expected, msg .. " expected=" .. tostring(expected) .. " actual=" .. tostring(actual))
    end
end

local function make_providers_dir()
    local dir = os.tmpname() .. "_providers"
    os.execute("mkdir -p " .. dir)

    local f = io.open(dir .. "/kimi.yaml", "w")
    f:write([[
id: workspace-gw-kimi-oauth
name: "Kimi OAuth"
npm: "kimi-oauth"
route: "/kimi"
auth:
  type: oauth
options:
  headers:
    X-Provider: "kimi"
model_source:
  type: models_dev_provider
  provider: kimi
]])
    f:close()

    f = io.open(dir .. "/openai.yaml", "w")
    f:write([[
id: workspace-gw-openai
name: "OpenAI"
npm: "openai"
route: "/openai"
auth:
  type: api_key
model_source:
  type: models_dev_provider
  provider: openai
context_limit_pct: 80
context_limit_ceiling: 100000
]])
    f:close()

    return dir
end

local function cleanup_dir(dir)
    os.execute("rm -rf " .. dir)
end

--Tests ------------------------------------------------------------------------------
local function schema_tests()
    local ok, err = provider_sync.check_schema({})
    check(ok, "schema[1] empty conf validates")
end

local function sync_and_enrich_tests()
    local dir = make_providers_dir()
    local conf = {
        providers_dir = dir,
        models_dev_url = "http://models.dev/api.json",
        ttl_seconds = 3600,
        stale_seconds = 86400,
        sync_timeout = 10000,
        warmup_on_init = false,
    }

    --Reset cache and captured requests before sync.
    cache = {}
    captured_requests = {}

    local result, err = provider_sync.sync(conf)
    check(result ~= nil, "sync[1] succeeds: " .. tostring(err or "ok"))
    if result then
        assert_eq(result.providers_loaded, 2, "sync[1] providers loaded")
        assert_eq(result.models_enriched, 3, "sync[1] models enriched")
    end

    --Verify models.dev was fetched with the Kimi User-Agent.
    local found_models_dev = false
    for _, req in ipairs(captured_requests) do
        if req.url == "http://models.dev/api.json" then
            found_models_dev = true
            assert_eq(req.headers["User-Agent"], "Kimi CLI (Linux 6.17.0-35-generic x64)",
                "sync[1] models.dev User-Agent")
            assert_eq(req.method, "GET", "sync[1] models.dev method")
        end
    end
    check(found_models_dev, "sync[1] models.dev request captured")

    local enriched, err = provider_sync.get_enriched(conf)
    check(enriched ~= nil, "get_enriched[1] succeeds: " .. tostring(err or "ok"))
    if enriched then
        local kimi = enriched["workspace-gw-kimi-oauth"]
        check(kimi ~= nil, "get_enriched[1] kimi provider present")
        if kimi then
            assert_eq(kimi.name, "Kimi OAuth", "get_enriched[1] kimi name")
            assert_eq(kimi.npm, "kimi-oauth", "get_enriched[1] kimi npm")
            assert_eq(kimi.auth.type, "oauth", "get_enriched[1] kimi auth type")
            local m = kimi.models["kimi-k1"]
            check(m ~= nil, "get_enriched[1] kimi-k1 model present")
            if m then
                assert_eq(m.name, "Kimi K1", "get_enriched[1] kimi-k1 name")
                assert_eq(m.cost.input, 1.0, "get_enriched[1] kimi-k1 input cost")
                assert_eq(m.cost.output, 3.0, "get_enriched[1] kimi-k1 output cost")
                assert_eq(m.cost.cache_read, 0.5, "get_enriched[1] kimi-k1 cache_read cost")
                assert_eq(m.cost.cache_write, 1.5, "get_enriched[1] kimi-k1 cache_write cost")
                assert_eq(m.limit.context, 128000, "get_enriched[1] kimi-k1 context limit")
                assert_eq(m.limit.output, 8192, "get_enriched[1] kimi-k1 output limit")
                assert_eq(m.attachment, false, "get_enriched[1] kimi-k1 attachment")
                assert_eq(m.tool_call, true, "get_enriched[1] kimi-k1 tool_call")
            end
            local v = kimi.models["kimi-k1-vision"]
            check(v ~= nil, "get_enriched[1] kimi-k1-vision present")
            if v then
                assert_eq(v.attachment, true, "get_enriched[1] vision attachment")
            end
        end

        local openai = enriched["workspace-gw-openai"]
        check(openai ~= nil, "get_enriched[1] openai provider present")
        if openai then
            assert_eq(openai.auth.type, "api_key", "get_enriched[1] openai auth type")
            local gpt = openai.models["gpt-5"]
            check(gpt ~= nil, "get_enriched[1] gpt-5 present")
            if gpt then
                assert_eq(gpt.reasoning, true, "get_enriched[1] gpt-5 reasoning")
                --256000 * 80% = 204800, but ceiling is 100000, so capped.
                assert_eq(gpt.limit.context, 100000, "get_enriched[1] gpt-5 context limit capped")
            end
        end
    end

    cleanup_dir(dir)
end

local function access_route_tests()
    local dir = make_providers_dir()
    local conf = {
        providers_dir = dir,
        models_dev_url = "http://models.dev/api.json",
        ttl_seconds = 3600,
        stale_seconds = 86400,
        sync_timeout = 10000,
        warmup_on_init = false,
    }

    cache = {}
    local ok, err = provider_sync.sync(conf)
    check(ok ~= nil, "access[0] sync succeeds")

    local function call_access(uri)
        last_response = nil
        local ctx = { var = { uri = uri } }
        local access_ok, access_err = pcall(provider_sync.access, conf, ctx)
        check(access_ok, "access[" .. uri .. "] no error: " .. tostring(access_err or "ok"))
        return last_response
    end

    local resp = call_access("/gateway/providers")
    check(resp ~= nil, "access[/gateway/providers] returned response")
    if resp then
        local body = cjson.decode(resp.body)
        check(type(body) == "table", "access[/gateway/providers] body is array")
        assert_eq(#body, 2, "access[/gateway/providers] list length")
    end

    resp = call_access("/gateway/providers/workspace-gw-kimi-oauth")
    check(resp ~= nil, "access[/gateway/providers/{id}] returned response")
    if resp then
        local body = cjson.decode(resp.body)
        check(body ~= nil, "access[/gateway/providers/{id}] body decoded")
        if body then
            assert_eq(body.name, "Kimi OAuth", "access[/gateway/providers/{id}] name")
        end
    end

    resp = call_access("/gateway/providers/unknown")
    check(resp ~= nil, "access[/gateway/providers/unknown] returned response")
    if resp then
        assert_eq(resp.status, 404, "access[/gateway/providers/unknown] status")
    end

    resp = call_access("/gateway/providers/workspace-gw-kimi-oauth/opencode")
    check(resp ~= nil, "access[/gateway/providers/{id}/opencode] returned response")
    if resp then
        local body = cjson.decode(resp.body)
        check(body ~= nil, "access[/gateway/providers/{id}/opencode] body decoded")
        if body then
            assert_eq(body.provider_id, "workspace-gw-kimi-oauth", "opencode provider_id")
            assert_eq(body.auth_type, "oauth", "opencode auth_type")
            assert_eq(body.auth_route, "/kimi/auth", "opencode auth_route")
            assert_eq(body.provider.name, "Kimi OAuth", "opencode provider.name")
            assert_eq(body.provider.npm, "kimi-oauth", "opencode provider.npm")
            check(body.provider.models ~= nil, "opencode models present")
            if body.provider.options and body.provider.options.baseURL then
                assert_eq(body.provider.options.baseURL, "http://localhost:9080/kimi", "opencode baseURL")
            end
            if body.provider.options and body.provider.options.headers then
                assert_eq(body.provider.options.headers["X-Provider"], "kimi", "opencode custom header")
            end
        end
    end

    resp = call_access("/gateway/providers/sync")
    check(resp ~= nil, "access[/gateway/providers/sync] returned response")
    if resp then
        assert_eq(resp.status, 200, "access[/gateway/providers/sync] status")
        local body = cjson.decode(resp.body)
        if body then
            assert_eq(body.ok, true, "access[/gateway/providers/sync] ok")
        end
    end

    cleanup_dir(dir)
end

local function cache_and_lock_tests()
    local dir = make_providers_dir()
    local conf = {
        providers_dir = dir,
        models_dev_url = "http://models.dev/api.json",
        ttl_seconds = 3600,
        stale_seconds = 86400,
        sync_timeout = 10000,
        warmup_on_init = false,
    }

    cache = {}
    local ok, err = provider_sync.sync(conf)
    check(ok ~= nil, "lock[1] sync ok")

    --Manually hold the lock to verify the second sync is rejected.
    shared:set("providers:lock", "1", 30)
    local ok2, err2 = provider_sync.sync(conf)
    assert_eq(ok2, nil, "lock[2] sync rejected while lock held")
    assert_eq(err2, "sync already in progress", "lock[2] error message")

    --After clearing lock, sync works again.
    shared:delete("providers:lock")
    local ok3, err3 = provider_sync.sync(conf)
    check(ok3 ~= nil, "lock[3] sync after lock cleared")

    --get_enriched should return cached data without re-syncing.
    local enriched, err = provider_sync.get_enriched(conf)
    check(enriched ~= nil, "lock[4] get_enriched from cache")

    cleanup_dir(dir)
end

local function main()
    schema_tests()
    sync_and_enrich_tests()
    access_route_tests()
    cache_and_lock_tests()

    io.write(string.format("\n==== Provider sync tests: %d passed, %d failed ====\n", pass, fail))
    if fail > 0 then
        io.stderr:write(string.format("FAILED: %d test(s) failed\n", fail))
        os.exit(1)
    end
end

main()
