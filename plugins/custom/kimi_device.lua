local core = require("apisix.core")
local cjson = require("cjson.safe")
local http = require("resty.http")

local KIMI_USER_AGENT = "Kimi CLI (Linux 6.17.0-35-generic x64)"

local M = {}

local function encode_form_component(value)
    return tostring(value):gsub("([^A-Za-z0-9%-_%.%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

local function post_form(url, params, timeout)
    local httpc = http.new()
    httpc:set_timeout(timeout or 30000)

    local parts = {}
    for k, v in pairs(params) do
        table.insert(parts, encode_form_component(k) .. "=" .. encode_form_component(v))
    end
    local form_body = table.concat(parts, "&")

    local res, err = httpc:request_uri(url, {
        method = "POST",
        body = form_body,
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
            ["Accept"] = "application/json",
            ["User-Agent"] = KIMI_USER_AGENT,
        },
        ssl_verify = false,
    })

    if not res then
        return nil, "http request failed: " .. (err or "unknown")
    end

    local data = cjson.decode(res.body or "{}") or {}
    return { status = res.status, data = data }, nil
end

function M.request_device_authorization(conf)
    local url = conf.oauth_host:gsub("/$", "") .. "/api/oauth/device_authorization"
    local res, err = post_form(url, { client_id = conf.client_id })
    if not res then return nil, err end
    if res.status ~= 200 then
        return nil, "device authorization failed (HTTP " .. res.status .. ")"
    end
    local data = res.data
    if type(data.user_code) ~= "string" or data.user_code == "" then
        return nil, "device authorization response missing user_code"
    end
    if type(data.device_code) ~= "string" or data.device_code == "" then
        return nil, "device authorization response missing device_code"
    end
    return {
        user_code = data.user_code,
        device_code = data.device_code,
        verification_uri = data.verification_uri or "",
        verification_uri_complete = data.verification_uri_complete or "",
        expires_in = tonumber(data.expires_in) or 900,
        interval = tonumber(data.interval) or 5,
    }, nil
end

function M.poll_device_token(conf, device_code)
    local url = conf.oauth_host:gsub("/$", "") .. "/api/oauth/token"
    local res, err = post_form(url, {
        client_id = conf.client_id,
        device_code = device_code,
        grant_type = "urn:ietf:params:oauth:grant-type:device_code",
    })
    if not res then return nil, err end

    local data = res.data
    if res.status == 200 and type(data.access_token) == "string" then
        if type(data.refresh_token) ~= "string" or data.refresh_token == "" then
            return nil, "token response missing refresh_token"
        end
        local expires_in = tonumber(data.expires_in)
        if not expires_in or expires_in <= 0 then
            return nil, "token response missing expires_in"
        end
        return {
            access_token = data.access_token,
            refresh_token = data.refresh_token,
            expires_in = expires_in,
            expires_at = ngx.time() + expires_in,
            token_type = data.token_type or "Bearer",
            scope = data.scope or "",
        }, nil
    end

    if res.status >= 500 then
        return nil, "token polling server error (HTTP " .. res.status .. ")"
    end

    local error_code = type(data.error) == "string" and data.error or "unknown_error"
    if error_code == "authorization_pending" or error_code == "slow_down" then
        return { pending = true, error_code = error_code }, nil
    end
    if error_code == "expired_token" then
        return { expired = true }, nil
    end
    if error_code == "access_denied" then
        return nil, "authorization denied"
    end
    return nil, "token polling failed (HTTP " .. res.status .. "): " .. error_code
end

function M.refresh_access_token(conf, refresh_token)
    local url = conf.oauth_host:gsub("/$", "") .. "/api/oauth/token"
    local res, err = post_form(url, {
        client_id = conf.client_id,
        refresh_token = refresh_token,
        grant_type = "refresh_token",
    })
    if not res then return nil, err end

    local data = res.data
    if res.status == 200 and type(data.access_token) == "string" then
        if type(data.refresh_token) ~= "string" or data.refresh_token == "" then
            return nil, "refresh response missing refresh_token"
        end
        local expires_in = tonumber(data.expires_in)
        if not expires_in or expires_in <= 0 then
            return nil, "refresh response missing expires_in"
        end
        return {
            access_token = data.access_token,
            refresh_token = data.refresh_token,
            expires_in = expires_in,
            expires_at = ngx.time() + expires_in,
            token_type = data.token_type or "Bearer",
            scope = data.scope or "",
        }, nil
    end

    if res.status == 401 or res.status == 403 then
        return nil, "invalid_grant"
    end
    if res.status >= 500 then
        return nil, "refresh server error (HTTP " .. res.status .. ")"
    end
    return nil, "refresh failed (HTTP " .. res.status .. ")"
end

return M
