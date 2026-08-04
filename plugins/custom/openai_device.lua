local cjson = require("cjson.safe")
local http = require("resty.http")

local M = {}

local function form_encode(value)
    return tostring(value):gsub("([^A-Za-z0-9%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

local function post_json(url, body)
    local httpc = http.new()
    local res, err = httpc:request_uri(url, {
        method = "POST",
        body = cjson.encode(body),
        headers = {
            ["Content-Type"] = "application/json",
            ["Accept"] = "application/json",
            ["User-Agent"] = "opencode/1.18.3",
        },
        timeout = 30000,
        ssl_verify = false,
    })
    if not res then return nil, "http request failed: " .. (err or "unknown") end
    return { status = res.status, data = cjson.decode(res.body or "{}") or {} }, nil
end

local function post_form(url, params)
    local httpc = http.new()
    local parts = {}
    for k, v in pairs(params) do
        table.insert(parts, form_encode(k) .. "=" .. form_encode(v))
    end
    local res, err = httpc:request_uri(url, {
        method = "POST",
        body = table.concat(parts, "&"),
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
            ["Accept"] = "application/json",
            ["User-Agent"] = "opencode/1.18.3",
        },
        timeout = 30000,
        ssl_verify = false,
    })
    if not res then return nil, "http request failed: " .. (err or "unknown") end
    return { status = res.status, data = cjson.decode(res.body or "{}") or {} }, nil
end

function M.request_device_authorization(conf)
    local res, err = post_json(conf.oauth_host .. "/api/accounts/deviceauth/usercode", {
        client_id = conf.client_id,
    })
    if not res then return nil, err end
    if res.status ~= 200 then return nil, "device authorization failed (HTTP " .. res.status .. ")" end
    local data = res.data
    if not data.device_auth_id or not data.user_code then
        return nil, "device authorization response missing device_auth_id or user_code"
    end
    return {
        device_code = data.device_auth_id,
        user_code = data.user_code,
        verification_uri = conf.oauth_host .. "/codex/device",
        verification_uri_complete = conf.oauth_host .. "/codex/device",
        interval = tonumber(data.interval) or 5,
        expires_in = tonumber(data.expires_in) or 900,
    }
end

function M.poll_device_token(conf, device_code, user_code)
    local res, err = post_json(conf.oauth_host .. "/api/accounts/deviceauth/token", {
        device_auth_id = device_code,
        user_code = user_code,
    })
    if not res then return nil, err end
    if res.status == 403 or res.status == 404 then
        return { pending = true }, nil
    end
    if res.status ~= 200 then return nil, "device polling failed (HTTP " .. res.status .. ")" end
    local data = res.data
    if not data.authorization_code or not data.code_verifier then
        return nil, "device response missing authorization_code or code_verifier"
    end
    local token, token_err = post_form(conf.oauth_host .. "/oauth/token", {
        grant_type = "authorization_code",
        code = data.authorization_code,
        redirect_uri = conf.oauth_host .. "/deviceauth/callback",
        client_id = conf.client_id,
        code_verifier = data.code_verifier,
    })
    if not token then return nil, token_err end
    if token.status ~= 200 or not token.data.access_token then
        return nil, "token exchange failed (HTTP " .. token.status .. ")"
    end
    local value = token.data
    return {
        access_token = value.access_token,
        refresh_token = value.refresh_token,
        expires_in = tonumber(value.expires_in) or 3600,
        expires_at = ngx.time() + (tonumber(value.expires_in) or 3600),
        token_type = value.token_type or "Bearer",
        id_token = value.id_token,
    }
end

function M.refresh_access_token(conf, refresh_token)
    local res, err = post_form(conf.oauth_host .. "/oauth/token", {
        grant_type = "refresh_token",
        refresh_token = refresh_token,
        client_id = conf.client_id,
    })
    if not res then return nil, err end
    if res.status == 401 or res.status == 403 then return nil, "invalid_grant" end
    if res.status ~= 200 or not res.data.access_token then
        return nil, "refresh failed (HTTP " .. res.status .. ")"
    end
    local value = res.data
    return {
        access_token = value.access_token,
        refresh_token = value.refresh_token or refresh_token,
        expires_in = tonumber(value.expires_in) or 3600,
        expires_at = ngx.time() + (tonumber(value.expires_in) or 3600),
        token_type = value.token_type or "Bearer",
        id_token = value.id_token,
    }
end

return M
