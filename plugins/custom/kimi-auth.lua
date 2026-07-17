local core = require("apisix.core")
local cjson = require("cjson.safe")
local jwt = require("apisix.plugins.kimi_jwt")
local device = require("apisix.plugins.kimi_device")
local tokens = require("apisix.plugins.kimi_tokens")

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

local function starts_with(value, prefix)
    return value and value:sub(1, #prefix) == prefix
end

local function read_json_body(ctx)
    local body = core.request.get_body()
    if not body or body == "" then return {} end
    if type(body) == "table" then
        --APISIX may return a table when the body is large; not expected here.
        body = body[1] or ""
    end
    local ok, parsed = pcall(cjson.decode, body)
    if not ok or type(parsed) ~= "table" then return {} end
    return parsed
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

    local store_err
    _, store_err = tokens.store_device(conf, auth.device_code, {
        device_code = auth.device_code,
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
        device_code = auth.device_code,
        interval = auth.interval,
        expires_in = auth.expires_in,
    }
end

local function poll_device_flow(conf, ctx)
    local body = read_json_body(ctx)
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

    local result, err = device.poll_device_token(conf, device_code)
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

local function refresh_session(conf, session)
    local refreshed, err = device.refresh_access_token(conf, session.refresh_token)
    if not refreshed then
        if err == "invalid_grant" then
            return nil, "invalid_grant"
        end
        return nil, err
    end
    return refreshed, nil
end

local function ensure_fresh_token(conf, bearer, session)
    local access_token = session.access_token
    if jwt.is_expiring(access_token, conf.refresh_threshold) then
        local refreshed, err = refresh_session(conf, session)
        if not refreshed then
            return nil, err
        end
        local updated = session_record(bearer, refreshed, session.session_id)
        updated.sub = session.sub
        updated.issued_access_token_hash = session.issued_access_token_hash
        local _, store_err = tokens.store_session(conf, bearer, updated)
        if store_err then
            core.log.error("kimi-auth: failed to update session after refresh: ", store_err)
            --Continue with refreshed token even if storage fails.
        end
        access_token = refreshed.access_token
    end
    return access_token, nil
end

local function load_session_by_bearer(conf, bearer)
    local session, err = tokens.load_session_by_bearer(conf, bearer)
    if session then return session, nil end

    --Bearer may be a rotated access_token; try looking up by JWT subject.
    local sub = jwt.subject(bearer)
    if sub then
        --Subject index is optional; fall back gracefully if not present.
        local sub_session, sub_err = tokens.load_session_by_bearer(conf, sub)
        if sub_session then
            return sub_session, nil
        end
        if sub_err and not sub_err:find("not found") then
            return nil, sub_err
        end
    end

    return nil, err or "session not found"
end

function plugin.access(conf, ctx)
    local uri = ctx.var.uri or ""

    if uri == "/kimi/auth/device" then
        return start_device_flow(conf, ctx)
    end
    if uri == "/kimi/auth/device/poll" then
        return poll_device_flow(conf, ctx)
    end

    local auth_header = core.request.header(ctx, "Authorization")
    local bearer = extract_bearer(auth_header)
    if not bearer or bearer == "" then
        return 401, { error = "kimi-auth: missing Authorization header" }
    end

    if starts_with(bearer, "sk-") then
        return 401, { error = "kimi-auth: API keys are not accepted on /kimi; use /kimi-key" }
    end

    local session, lookup_err = load_session_by_bearer(conf, bearer)
    if not session then
        core.log.warn("kimi-auth: session lookup failed: ", lookup_err or "unknown")
        return 401, { error = "kimi-auth: session not found; run device flow first" }
    end

    local fresh, refresh_err = ensure_fresh_token(conf, bearer, session)
    if not fresh then
        if refresh_err == "invalid_grant" then
            tokens.delete_session(conf, bearer)
            return 401, { error = "kimi-auth: re-authenticate" }
        end
        core.log.error("kimi-auth: token refresh failed: ", refresh_err or "unknown")
        return 503, { error = "kimi-auth: token refresh failed" }
    end

    local key_id = session.issued_access_token_hash and session.issued_access_token_hash:sub(1, 16)
        or jwt.token_hash(bearer):sub(1, 16)
    local user_id = session.sub or ""
    local tenant_id = session.session_id and session.session_id ~= "" and session.session_id or "default"

    ngx.req.set_header("Authorization", "Bearer " .. fresh)
    ngx.req.set_header("X-Gateway-Key-Id", key_id)
    ngx.req.set_header("X-Gateway-Tenant-Id", tenant_id)
    ngx.req.set_header("X-Gateway-User-Id", user_id)
    ngx.req.set_header("X-Gateway-Rate-Limit-RPM", "100")
    ngx.req.set_header("X-Gateway-Rate-Limit-Window", "60")

    ctx.consumer = {
        username = key_id,
    }
end

return plugin
