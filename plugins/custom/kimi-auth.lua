local core = require("apisix.core")
local jwt = require("apisix.plugins.kimi_jwt")
local device = require("apisix.plugins.kimi_device")
local tokens = require("apisix.plugins.kimi_tokens")
local ok, oauth_broker = pcall(require, "apisix.plugins.oauth_broker")
if not ok then oauth_broker = require("oauth_broker") end
local ok_session, session = pcall(require, "apisix.plugins.oauth_session")
if not ok_session then session = require("oauth_session") end

local plugin_name = "kimi-auth"

local plugin = {
    version = 0.1,
    priority = 2560,
    name = plugin_name,
}

plugin.schema = {
    type = "object",
    properties = {
        oauth_host = {
            type = "string",
            default = "https://auth.kimi.com",
        },
        api_host = {
            type = "string",
            default = "https://api.kimi.com/coding",
        },
        client_id = {
            type = "string",
            default = "17e5f671-d194-4dfb-9706-5516cb48c098",
        },
        openbao_addr = {
            type = "string",
            default = "http://openbao:8200",
        },
        openbao_token_env = {
            type = "string",
            default = "OPENBAO_TOKEN",
        },
        token_prefix = {
            type = "string",
            default = "secret/data/gateway/kimi-tokens/",
        },
        device_prefix = {
            type = "string",
            default = "secret/data/gateway/kimi-device/",
        },
        refresh_threshold = {
            type = "integer",
            default = 300,
        },
        ssl_verify = {
            type = "boolean",
            default = true,
        },
    },
}

function plugin.check_schema(conf)
    return core.schema.check(plugin.schema, conf)
end

local function starts_with(value, prefix)
    return value and value:sub(1, #prefix) == prefix
end

local function session_record(bearer, token_info, session_id)
    local sub = jwt.subject(bearer)
    return {
        access_token = token_info.access_token,
        refresh_token = token_info.refresh_token,
        token_type = token_info.token_type,
        expires_in = token_info.expires_in,
        expires_at = token_info.expires_at,
        scope = token_info.scope,
        issued_access_token_hash = jwt.token_hash(bearer),
        live_access_token_hash = jwt.token_hash(token_info.access_token),
        sub = sub,
        session_id = session_id or "",
        updated_at = ngx.http_time(ngx.time()),
    }
end

local function start_device_flow(conf, ctx)
    local session_id = ngx.var.arg_session or ""
    local auth, err = device.request_device_authorization(conf)
    if not auth then
        core.log.error("kimi-auth: device authorization failed: ", err or "unknown")
        return 502, { error = "kimi-auth: device authorization failed: " .. (err or "unknown") }
    end

    local client_device_code = oauth_broker.gateway_device_code(auth.device_code)
    local store_err
    _, store_err = tokens.store_device(conf, client_device_code, {
        device_code = auth.device_code,
        upstream_device_code = auth.device_code,
        session_id = session_id,
        expires_at = ngx.time() + auth.expires_in,
        interval = auth.interval,
        created_at = ngx.http_time(ngx.time()),
    })
    if store_err then
        core.log.error("kimi-auth: failed to store device record: ", store_err)
        return 503, { error = "kimi-auth: cannot reach token store" }
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

local function poll_device_flow(conf, ctx)
    local body = session.json_body()
    local device_code = body.device_code
    if not device_code or device_code == "" then
        return 400, { error = "kimi-auth: missing device_code" }
    end

    local pending, load_err = tokens.load_device(conf, device_code)
    if not pending then
        core.log.warn("kimi-auth: device record not found: ", load_err or "unknown")
        return 400, { error = "kimi-auth: device session expired or invalid" }
    end

    if tonumber(pending.expires_at) and ngx.time() > tonumber(pending.expires_at) then
        tokens.delete_device(conf, device_code)
        return 400, { error = "kimi-auth: device session expired" }
    end

    local result, err = device.poll_device_token(conf, pending.upstream_device_code or pending.device_code)
    if not result then
        core.log.error("kimi-auth: token exchange failed: ", err or "unknown")
        return 502, { error = "kimi-auth: token exchange failed: " .. (err or "unknown") }
    end

    if result.pending then
        return 202, { error = "authorization_pending", error_code = result.error_code }
    end

    if result.expired then
        tokens.delete_device(conf, device_code)
        return 400, { error = "kimi-auth: device code expired" }
    end

    --Success: persist session and clean up pending device record.
    local bearer = result.access_token
    local record = session_record(bearer, result, pending.session_id)
    local _, store_err = tokens.store_session(conf, bearer, record)
    if store_err then
        core.log.error("kimi-auth: failed to store session: ", store_err)
        return 503, { error = "kimi-auth: cannot reach token store" }
    end
    tokens.delete_device(conf, device_code)

    local sub = jwt.subject(bearer)
    return 200, {
        access_token = result.access_token,
        expires_in = result.expires_in,
        account = { sub = sub },
        session_id = pending.session_id,
    }
end

local function load_session_by_bearer(conf, bearer_value)
    --Sessions resolve by sha256(issued access token) only. Refresh rewrites
    --the same record, so the client-held credential resolves for the session
    --lifetime; any other bearer is an explicit 401.
    return tokens.load_session_by_bearer(conf, bearer_value)
end

local function ensure_fresh(conf, bearer_value, current)
    return session.ensure_fresh(conf, tokens, bearer_value, current, {
        prefix = "kimi-auth",
        refresh = device.refresh_access_token,
        build_record = function(b, refreshed, old)
            local record = session_record(b, refreshed, old.session_id)
            record.sub = old.sub
            record.issued_access_token_hash = old.issued_access_token_hash
            return record
        end,
    })
end

function plugin.access(conf, ctx)
    local uri = ctx.var.uri or ""

    if uri == "/kimi/auth/device" then
        return start_device_flow(conf, ctx)
    end
    if uri == "/kimi/auth/device/poll" then
        return poll_device_flow(conf, ctx)
    end

    local bearer = session.bearer(ctx)
    if not bearer or bearer == "" then
        return 401, { error = "kimi-auth: missing Authorization header" }
    end

    if starts_with(bearer, "sk-") then
        return 401, { error = "kimi-auth: API keys are not accepted on /kimi; use /kimi-key" }
    end

    local session_record_loaded, lookup_err = load_session_by_bearer(conf, bearer)
    if not session_record_loaded then
        core.log.warn("kimi-auth: session lookup failed: ", lookup_err or "unknown")
        return 401, { error = "kimi-auth: session not found; run device flow first" }
    end

    local fresh, fresh_session, status, err_body = ensure_fresh(conf, bearer, session_record_loaded)
    if not fresh then
        return status, err_body
    end
    local fresh_record = fresh_session

    local key_id = fresh_record.issued_access_token_hash and fresh_record.issued_access_token_hash:sub(1, 16)
        or jwt.token_hash(bearer):sub(1, 16)
    local user_id = fresh_record.sub or ""
    local tenant_id = fresh_record.session_id and fresh_record.session_id ~= "" and fresh_record.session_id or "default"

    ngx.req.set_header("Authorization", "Bearer " .. fresh)
    session.set_meta_headers(key_id, user_id, tenant_id)

    ctx.consumer = {
        username = key_id,
    }
end

return plugin
