-- Generic OAuth device/browser authorization plugin.
--
-- One plugin serves every OAuth provider: all provider differences are
-- per-route config (see conf/apisix.yaml). Protocol behavior lives in
-- oauth_device.lua engines (rfc8628, chatgpt_device); session storage in
-- oauth_store.lua (OpenBao, prefix-parameterized); refresh/header logic in
-- oauth_session.lua. No provider names appear in this file.
--
-- Endpoint layout on each route (auth_base = e.g. "/kimi/auth"):
--   POST {auth_base}/device             start device flow
--   POST {auth_base}/device/poll        poll/exchange
--   POST {auth_base}/browser            start browser PKCE flow   (browser_flow)
--   POST {auth_base}/browser/callback   complete browser flow     (browser_flow)
-- Anything else on the route is proxied with bearer-session auth + refresh.
local core = require("apisix.core")
local cjson = require("cjson.safe")
local jwt = require("apisix.plugins.oauth_jwt")
local device = require("apisix.plugins.oauth_device")
local tokens = require("apisix.plugins.oauth_store")
local ok, oauth_broker = pcall(require, "apisix.plugins.oauth_broker")
if not ok then oauth_broker = require("oauth_broker") end
local ok_session, session = pcall(require, "apisix.plugins.oauth_session")
if not ok_session then session = require("oauth_session") end

local plugin_name = "oauth-auth"

local plugin = {
    version = 0.1,
    priority = 2560,
    name = plugin_name,
}

plugin.schema = {
    type = "object",
    properties = {
        auth_base = { type = "string" },
        protocol = { type = "string", enum = { "rfc8628", "chatgpt_device" }, default = "rfc8628" },
        oauth_host = { type = "string" },
        client_id = { type = "string" },
        user_agent = { type = "string", default = "workspace-gateway/0.1" },
        request_encoding = { type = "string", enum = { "form", "json" }, default = "form" },
        device_authorize_path = { type = "string" },
        device_poll_path = { type = "string" },
        device_callback_path = { type = "string" },
        verification_path = { type = "string" },
        token_path = { type = "string" },
        browser_flow = { type = "boolean", default = false },
        browser_redirect_uri = { type = "string", default = "http://localhost:1455/auth/callback" },
        authorize_path = { type = "string" },
        authorize_params = { type = "object" },
        openbao_addr = { type = "string", default = "http://openbao:8200" },
        openbao_token_env = { type = "string", default = "OPENBAO_TOKEN" },
        token_prefix = { type = "string" },
        device_prefix = { type = "string" },
        refresh_threshold = { type = "integer", default = 300 },
        refresh_rotation_required = { type = "boolean", default = true },
        ssl_verify = { type = "boolean", default = true },
        reject_key_prefix = { type = "string" },
        reject_key_pointer = { type = "string" },
        strip_request_fields = { type = "array", items = { type = "string" } },
        fixed_upstream_headers = { type = "object" },
        alias_headers = { type = "object" },
        account_claim_paths = {
            type = "array",
            items = {
                type = "object",
                properties = {
                    claim = { type = "string" },
                    field = { type = "string" },
                    index = { type = "integer", minimum = 1 },
                },
                required = { "claim" },
            },
        },
        account_header = { type = "string" },
    },
    required = { "auth_base", "oauth_host", "client_id", "device_authorize_path",
        "token_path", "token_prefix", "device_prefix" },
}

function plugin.check_schema(conf)
    return core.schema.check(plugin.schema, conf)
end

local function starts_with(value, prefix)
    return value and prefix and value:sub(1, #prefix) == prefix
end

local function claim_path_value(claims, entries)
    if type(claims) ~= "table" then return nil end
    for _, entry in ipairs(entries or {}) do
        local value = claims[entry.claim]
        if entry.index and type(value) == "table" then
            value = value[entry.index]
        end
        if entry.field and type(value) == "table" then
            value = value[entry.field]
        end
        if type(value) == "string" and value ~= "" then return value end
        if type(value) == "number" then return tostring(value) end
    end
    return nil
end

local function account_id(conf, result)
    if not conf.account_claim_paths then return nil end
    return claim_path_value(jwt.decode_claims(result.id_token), conf.account_claim_paths)
        or claim_path_value(jwt.decode_claims(result.access_token), conf.account_claim_paths)
end

local function session_record(conf, bearer, result, session_id)
    return {
        access_token = result.access_token,
        refresh_token = result.refresh_token,
        token_type = result.token_type,
        expires_in = result.expires_in,
        expires_at = result.expires_at,
        scope = result.scope,
        id_token = result.id_token,
        issued_access_token_hash = jwt.token_hash(bearer),
        live_access_token_hash = jwt.token_hash(result.access_token),
        sub = jwt.subject(bearer) or "",
        account_id = account_id(conf, result),
        session_id = session_id or "",
        updated_at = ngx.http_time(ngx.time()),
    }
end

local function start_device_flow(conf)
    local session_id = ngx.var.arg_session or ""
    local engine = device.engine(conf)
    local auth, err = engine.request_device_authorization(conf)
    if not auth then
        core.log.error(plugin_name, ": device authorization failed: ", err or "unknown")
        return 502, { error = plugin_name .. ": device authorization failed: " .. (err or "unknown") }
    end

    local client_device_code = oauth_broker.gateway_device_code(auth.device_code)
    local _, store_err = tokens.store_device(conf, client_device_code, {
        device_code = auth.device_code,
        upstream_device_code = auth.device_code,
        user_code = auth.user_code,
        session_id = session_id,
        expires_at = ngx.time() + auth.expires_in,
        interval = auth.interval,
        created_at = ngx.http_time(ngx.time()),
    })
    if store_err then
        core.log.error(plugin_name, ": failed to store device record: ", store_err)
        return 503, { error = plugin_name .. ": cannot reach token store" }
    end

    return 200, {
        verification_uri = auth.verification_uri,
        verification_uri_complete = auth.verification_uri_complete,
        user_code = auth.user_code,
        device_code = client_device_code,
        interval = auth.interval,
        expires_in = auth.expires_in,
    }
end

local function poll_device_flow(conf)
    local body = session.json_body()
    local device_code = body.device_code
    if not device_code or device_code == "" then
        return 400, { error = plugin_name .. ": missing device_code" }
    end

    local pending, load_err = tokens.load_device(conf, device_code)
    if not pending then
        core.log.warn(plugin_name, ": device record not found: ", load_err or "unknown")
        return 400, { error = plugin_name .. ": device session expired or invalid" }
    end

    if tonumber(pending.expires_at) and ngx.time() > tonumber(pending.expires_at) then
        tokens.delete_device(conf, device_code)
        return 400, { error = plugin_name .. ": device session expired" }
    end

    local engine = device.engine(conf)
    local result, err = engine.poll_device_token(conf,
        pending.upstream_device_code or pending.device_code, pending.user_code)
    if not result then
        core.log.error(plugin_name, ": token exchange failed: ", err or "unknown")
        return 502, { error = plugin_name .. ": token exchange failed: " .. (err or "unknown") }
    end

    if result.pending then
        return 202, { error = "authorization_pending", error_code = result.error_code }
    end

    if result.expired then
        tokens.delete_device(conf, device_code)
        return 400, { error = plugin_name .. ": device code expired" }
    end

    --Success: persist session and clean up pending device record.
    local bearer = result.access_token
    local record = session_record(conf, bearer, result, pending.session_id)
    local _, store_err = tokens.store_session(conf, bearer, record)
    if store_err then
        core.log.error(plugin_name, ": failed to store session: ", store_err)
        return 503, { error = plugin_name .. ": cannot reach token store" }
    end
    tokens.delete_device(conf, device_code)

    return 200, {
        access_token = result.access_token,
        expires_in = result.expires_in,
        account_id = record.account_id,
        session_id = pending.session_id,
    }
end

local function browser_start(conf)
    local input = session.json_body()
    local redirect_uri = input.redirect_uri or conf.browser_redirect_uri
    if redirect_uri ~= conf.browser_redirect_uri then
        return 400, { error = plugin_name .. ": unsupported redirect_uri" }
    end
    local verifier, challenge = device.generate_pkce()
    local state = device.generate_state()
    local session_id = ngx.var.arg_session or input.session or ""
    local _, store_err = tokens.store_device(conf, state, {
        flow = "browser",
        state = state,
        code_verifier = verifier,
        redirect_uri = redirect_uri,
        session_id = session_id,
        expires_at = ngx.time() + 600,
        created_at = ngx.http_time(ngx.time()),
    })
    if store_err then return 503, { error = plugin_name .. ": cannot reach token store" } end
    return 200, {
        authorization_url = device.browser_authorization_url(conf, redirect_uri, state, challenge),
        state = state,
        redirect_uri = redirect_uri,
        expires_in = 600,
    }
end

local function browser_callback(conf)
    local input = session.json_body()
    if not input.state or input.state == "" then
        return 400, { error = plugin_name .. ": missing state" }
    end
    if not input.code or input.code == "" then
        return 400, { error = plugin_name .. ": missing authorization code" }
    end
    --Single-use state: the atomic DELETE claims the record before the upstream
    --exchange. A replayed or concurrent callback observes "not found". If the
    --exchange then fails, the login must be restarted with a fresh state.
    local pending, consume_err = tokens.consume_device(conf, input.state)
    if not pending then
        if consume_err and consume_err:find("not found") then
            return 400, { error = plugin_name .. ": browser session expired, invalid, or already used" }
        end
        return 503, { error = plugin_name .. ": cannot reach token store" }
    end
    if pending.flow ~= "browser" then
        return 400, { error = plugin_name .. ": browser session expired or invalid" }
    end
    if not tonumber(pending.expires_at) or ngx.time() > tonumber(pending.expires_at) then
        return 400, { error = plugin_name .. ": browser session expired" }
    end
    if input.redirect_uri and input.redirect_uri ~= pending.redirect_uri then
        return 400, { error = plugin_name .. ": redirect_uri mismatch" }
    end
    local result, err = device.exchange_browser_code(
        conf, input.code, pending.redirect_uri, pending.code_verifier
    )
    if not result then return 502, { error = plugin_name .. ": " .. (err or "browser exchange failed") } end
    local issued = result.access_token
    local _, store_err = tokens.store_session(conf, issued,
        session_record(conf, issued, result, pending.session_id))
    if store_err then return 503, { error = plugin_name .. ": cannot reach token store" } end
    return 200, { access_token = issued, expires_in = result.expires_in, session_id = pending.session_id }
end

local function strip_request_fields(conf)
    local fields = conf.strip_request_fields
    if not fields or #fields == 0 then return end
    local raw = core.request.get_body() or ""
    if type(raw) == "table" then raw = raw[1] or "" end
    if raw == "" then return end
    local parsed_ok, parsed = pcall(cjson.decode, raw)
    if not parsed_ok or type(parsed) ~= "table" then return end
    local changed = false
    for _, field in ipairs(fields) do
        if parsed[field] ~= nil then
            parsed[field] = nil
            changed = true
        end
    end
    if changed then
        ngx.req.set_body_data(cjson.encode(parsed))
    end
end

local function apply_upstream_headers(conf, ctx, record)
    for name, value in pairs(conf.fixed_upstream_headers or {}) do
        ngx.req.set_header(name, value)
    end
    if conf.account_header and record.account_id then
        ngx.req.set_header(conf.account_header, record.account_id)
    end
    for from, to in pairs(conf.alias_headers or {}) do
        local value = core.request.header(ctx, from)
        if value and value ~= "" then ngx.req.set_header(to, value) end
    end
end

local function ensure_fresh(conf, bearer_value, current)
    return session.ensure_fresh(conf, tokens, bearer_value, current, {
        prefix = plugin_name,
        refresh = device.engine(conf).refresh_access_token,
        build_record = function(b, refreshed, old)
            local record = session_record(conf, b, refreshed, old.session_id)
            record.sub = old.sub or record.sub
            record.issued_access_token_hash = old.issued_access_token_hash
            record.account_id = old.account_id or record.account_id
            return record
        end,
    })
end

function plugin.access(conf, ctx)
    local uri = ctx.var.uri or ""

    if uri == conf.auth_base .. "/device" then
        return start_device_flow(conf)
    end
    if uri == conf.auth_base .. "/device/poll" then
        return poll_device_flow(conf)
    end
    if conf.browser_flow then
        if uri == conf.auth_base .. "/browser" then
            return browser_start(conf)
        end
        if uri == conf.auth_base .. "/browser/callback" then
            return browser_callback(conf)
        end
    end

    local bearer = session.bearer(ctx)
    if not bearer or bearer == "" then
        return 401, { error = plugin_name .. ": missing Authorization header" }
    end

    if conf.reject_key_prefix and starts_with(bearer, conf.reject_key_prefix) then
        local pointer = conf.reject_key_pointer or "an API-key route"
        return 401, { error = plugin_name .. ": API keys are not accepted on "
            .. conf.auth_base .. "; use " .. pointer }
    end

    local current, load_err = tokens.load_session_by_bearer(conf, bearer)
    if not current then
        core.log.warn(plugin_name, ": session lookup failed: ", load_err or "unknown")
        return 401, { error = plugin_name .. ": session not found; run device flow first" }
    end

    --ensure_fresh returns (access, session) on success and
    --(nil, status, body) on failure; read the returns accordingly.
    local fresh, second, third = ensure_fresh(conf, bearer, current)
    if not fresh then
        return second, third
    end
    local fresh_session = second

    local key_id = fresh_session.issued_access_token_hash
        and fresh_session.issued_access_token_hash:sub(1, 16)
        or jwt.token_hash(bearer):sub(1, 16)
    local user_id = fresh_session.sub or ""
    local tenant_id = fresh_session.session_id ~= ""
        and fresh_session.session_id or "default"

    ngx.req.set_header("Authorization", "Bearer " .. fresh)
    strip_request_fields(conf)
    apply_upstream_headers(conf, ctx, fresh_session)
    session.set_meta_headers(key_id, user_id, tenant_id)

    ctx.consumer = {
        username = key_id,
    }
end

return plugin
