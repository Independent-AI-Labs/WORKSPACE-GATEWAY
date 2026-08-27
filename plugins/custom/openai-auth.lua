local core = require("apisix.core")
local cjson = require("cjson.safe")
local jwt = require("apisix.plugins.kimi_jwt")
local device = require("apisix.plugins.openai_device")
local tokens = require("apisix.plugins.kimi_tokens")
local ok, oauth_broker = pcall(require, "apisix.plugins.oauth_broker")
if not ok then oauth_broker = require("oauth_broker") end

local plugin = { version = 0.1, priority = 2560, name = "openai-auth" }
local BROWSER_REDIRECT_URI = "http://localhost:1455/auth/callback"
plugin.schema = { type = "object", properties = {
    oauth_host = { type = "string", default = "https://auth.openai.com" },
    client_id = { type = "string", default = "app_EMoamEEZ73f0CkXaXp7hrann" },
    openbao_addr = { type = "string", default = "http://openbao:8200" },
    openbao_token_env = { type = "string", default = "OPENBAO_TOKEN" },
    token_prefix = { type = "string", default = "secret/data/gateway/openai-tokens/" },
    device_prefix = { type = "string", default = "secret/data/gateway/openai-device/" },
    refresh_threshold = { type = "integer", default = 300 },
    user_agent = { type = "string", default = "opencode/1.18.3" },
    ssl_verify = { type = "boolean", default = true },
} }

function plugin.check_schema(conf) return core.schema.check(plugin.schema, conf) end

local function bearer(ctx)
    local value = core.request.header(ctx, "Authorization")
    if type(value) == "table" then value = value[1] end
    return value and value:match("^%s*[Bb]earer%s+(.+)%s*$")
end

local function body()
    local raw = core.request.get_body() or "{}"
    if type(raw) == "table" then raw = raw[1] or "{}" end
    return cjson.decode(raw) or {}
end

local function remove_unsupported_params()
    local raw = core.request.get_body() or ""
    if type(raw) == "table" then raw = raw[1] or "" end
    if raw == "" then return end
    local parsed = cjson.decode(raw)
    if type(parsed) ~= "table" or parsed.max_output_tokens == nil then return end
    parsed.max_output_tokens = nil
    ngx.req.set_body_data(cjson.encode(parsed))
end

local function account_id(token)
    if not token then return nil end
    local part = token:match("^[^.]+%.([^.]+)%.")
    if not part then return nil end
    part = part:gsub("-", "+"):gsub("_", "/")
    local decoded = ngx.decode_base64(part)
    local claims = decoded and cjson.decode(decoded)
    if not claims then return nil end
    local auth = claims["https://api.openai.com/auth"] or {}
    return claims.chatgpt_account_id or auth.chatgpt_account_id
        or (claims.organizations and claims.organizations[1] and claims.organizations[1].id)
end

local function session_record(bearer_value, result, pending)
    return {
        access_token = result.access_token, refresh_token = result.refresh_token,
        expires_at = result.expires_at, id_token = result.id_token,
        expires_in = result.expires_in, token_type = result.token_type,
        scope = result.scope,
        issued_access_token_hash = jwt.token_hash(bearer_value),
        live_access_token_hash = jwt.token_hash(result.access_token),
        account_id = account_id(result.id_token) or account_id(result.access_token),
        session_id = pending.session_id or "", updated_at = ngx.http_time(ngx.time()),
    }
end

local function start(conf)
    local session_id = ngx.var.arg_session or ""
    local auth, err = device.request_device_authorization(conf)
    if not auth then return 502, { error = "openai-auth: " .. (err or "device authorization failed") } end
    local client_device_code = oauth_broker.gateway_device_code(auth.device_code)
    local _, store_err = tokens.store_device(conf, client_device_code, {
        device_code = auth.device_code, upstream_device_code = auth.device_code,
        user_code = auth.user_code,
        session_id = session_id, expires_at = ngx.time() + auth.expires_in,
        interval = auth.interval, created_at = ngx.http_time(ngx.time()),
    })
    if store_err then return 503, { error = "openai-auth: cannot reach token store" } end
    auth.device_code = client_device_code
    return 200, auth
end

local function poll(conf)
    local input = body()
    if not input.device_code or input.device_code == "" then return 400, { error = "openai-auth: missing device_code" } end
    local pending = tokens.load_device(conf, input.device_code)
    if not pending then return 400, { error = "openai-auth: device session expired or invalid" } end
    if ngx.time() > tonumber(pending.expires_at) then
        tokens.delete_device(conf, input.device_code)
        return 400, { error = "openai-auth: device session expired" }
    end
    local result, err = device.poll_device_token(conf, pending.upstream_device_code or pending.device_code, pending.user_code)
    if not result then return 502, { error = "openai-auth: " .. (err or "device polling failed") } end
    if result.pending then return 202, { error = result.error_code or "authorization_pending", error_code = result.error_code or "authorization_pending" } end
    local issued = result.access_token
    local _, store_err = tokens.store_session(conf, issued, session_record(issued, result, pending))
    if store_err then return 503, { error = "openai-auth: cannot reach token store" } end
    tokens.delete_device(conf, input.device_code)
    return 200, { access_token = issued, expires_in = result.expires_in, session_id = pending.session_id }
end

local function browser_start(conf)
    local input = body()
    local redirect_uri = input.redirect_uri or BROWSER_REDIRECT_URI
    if redirect_uri ~= BROWSER_REDIRECT_URI then
        return 400, { error = "openai-auth: unsupported redirect_uri" }
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
    if store_err then return 503, { error = "openai-auth: cannot reach token store" } end
    return 200, {
        authorization_url = device.browser_authorization_url(conf, redirect_uri, state, challenge),
        state = state,
        redirect_uri = redirect_uri,
        expires_in = 600,
    }
end

local function browser_callback(conf)
    local input = body()
    if not input.state or input.state == "" then
        return 400, { error = "openai-auth: missing state" }
    end
    if not input.code or input.code == "" then
        return 400, { error = "openai-auth: missing authorization code" }
    end
    local pending = tokens.load_device(conf, input.state)
    if not pending or pending.flow ~= "browser" then
        return 400, { error = "openai-auth: browser session expired or invalid" }
    end
    if not tonumber(pending.expires_at) or ngx.time() > tonumber(pending.expires_at) then
        tokens.delete_device(conf, input.state)
        return 400, { error = "openai-auth: browser session expired" }
    end
    if input.redirect_uri and input.redirect_uri ~= pending.redirect_uri then
        return 400, { error = "openai-auth: redirect_uri mismatch" }
    end
    local result, err = device.exchange_browser_code(
        conf, input.code, pending.redirect_uri, pending.code_verifier
    )
    if not result then return 502, { error = "openai-auth: " .. (err or "browser exchange failed") } end
    local issued = result.access_token
    local _, store_err = tokens.store_session(conf, issued, session_record(issued, result, pending))
    if store_err then return 503, { error = "openai-auth: cannot reach token store" } end
    tokens.delete_device(conf, input.state)
    return 200, { access_token = issued, expires_in = result.expires_in, session_id = pending.session_id }
end

function plugin.access(conf, ctx)
    local uri = ctx.var.uri or ""
    if uri == "/openai/auth/device" then return start(conf) end
    if uri == "/openai/auth/device/poll" then return poll(conf) end
    if uri == "/openai/auth/browser" then return browser_start(conf) end
    if uri == "/openai/auth/browser/callback" then return browser_callback(conf) end
    local value = bearer(ctx)
    if not value or value == "" then return 401, { error = "openai-auth: missing Authorization header" } end
    local session = tokens.load_session_by_bearer(conf, value)
    if not session then return 401, { error = "openai-auth: session not found; run device flow first" } end
    local access = session.access_token
    if jwt.is_expiring(access, conf.refresh_threshold) then
        local refreshed, err = device.refresh_access_token(conf, session.refresh_token)
        if not refreshed then
            if err == "invalid_grant" then tokens.delete_session(conf, value); return 401, { error = "openai-auth: re-authenticate" } end
            return 503, { error = "openai-auth: token refresh failed" }
        end
        local updated = session_record(value, refreshed, { session_id = session.session_id })
        updated.issued_access_token_hash = session.issued_access_token_hash
        tokens.store_session(conf, value, updated)
        access = refreshed.access_token
        session = updated
    end
    ngx.req.set_header("Authorization", "Bearer " .. access)
    remove_unsupported_params()
    if session.account_id then ngx.req.set_header("ChatGPT-Account-Id", session.account_id) end
    ngx.req.set_header("originator", "opencode")
    local session_header = core.request.header(ctx, "session-id")
        or core.request.header(ctx, "X-OpenCode-Session-Id")
    if session_header and session_header ~= "" then ngx.req.set_header("session-id", session_header) end
    ngx.req.set_header("X-Gateway-Key-Id", (session.issued_access_token_hash or jwt.token_hash(value)):sub(1, 16))
    ngx.req.set_header("X-Gateway-Tenant-Id", session.session_id ~= "" and session.session_id or "default")
    ngx.req.set_header("X-Gateway-Rate-Limit-RPM", "100")
    ngx.req.set_header("X-Gateway-Rate-Limit-Window", "60")
end

return plugin
