-- Generic OAuth device/browser protocol engines for oauth-auth.
--
-- Two engines, selected by conf.protocol:
--   rfc8628       - pure RFC 8628: form/JSON POSTs, standard error codes in
--                   the token response body (authorization_pending,
--                   slow_down, expired_token, access_denied).
--   chatgpt_device - ChatGPT/Codex custom two-step flow: JSON usercode +
--                    token exchange (device -> authorization_code ->
--                    /oauth/token), pending signalled by HTTP 403/404.
--
-- All provider differences are conf knobs (paths, encoding, user_agent).
-- No provider names appear in this file.
local cjson = require("cjson.safe")
local http = require("resty.http")
local random = require("resty.random")
local sha256_lib = require("resty.sha256")

local M = {}

local function sha256_bin(value)
    local digest = sha256_lib:new()
    digest:update(value)
    return digest:final()
end

local function url_encode(value)
    return tostring(value):gsub("([^A-Za-z0-9%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

local function base64url(value)
    return ngx.encode_base64(value):gsub("=+$", ""):gsub("%+", "-"):gsub("/", "_")
end

local function host(conf)
    return (conf.oauth_host or ""):gsub("/$", "")
end

local function post(conf, url, body, content_type)
    local httpc = http.new()
    httpc:set_timeout(30000)
    local res, err = httpc:request_uri(url, {
        method = "POST",
        body = body,
        headers = {
            ["Content-Type"] = content_type,
            ["Accept"] = "application/json",
            ["User-Agent"] = conf.user_agent or "workspace-gateway/0.1",
        },
        ssl_verify = conf.ssl_verify ~= false,
    })
    if not res then
        return nil, "http request failed: " .. (err or "unknown")
    end
    return { status = res.status, data = cjson.decode(res.body or "{}") or {} }, nil
end

local function post_form(conf, url, params)
    local parts = {}
    for k, v in pairs(params) do
        parts[#parts + 1] = url_encode(k) .. "=" .. url_encode(v)
    end
    return post(conf, url, table.concat(parts, "&"),
        "application/x-www-form-urlencoded")
end

local function post_json(conf, url, params)
    return post(conf, url, cjson.encode(params), "application/json")
end

local function post_auto(conf, url, params)
    if conf.request_encoding == "json" then
        return post_json(conf, url, params)
    end
    return post_form(conf, url, params)
end

local function token_from_response(res, opts)
    local data = res.data
    if type(data.access_token) ~= "string" or data.access_token == "" then
        return nil, "token response missing access_token"
    end
    local expires_in = tonumber(data.expires_in)
    if not expires_in or expires_in <= 0 then
        return nil, "token response missing expires_in"
    end
    if opts.require_refresh_token
        and (type(data.refresh_token) ~= "string" or data.refresh_token == "") then
        return nil, "token response missing refresh_token"
    end
    return {
        access_token = data.access_token,
        refresh_token = data.refresh_token or opts.keep_refresh_token,
        expires_in = expires_in,
        expires_at = ngx.time() + expires_in,
        token_type = data.token_type or "Bearer",
        id_token = data.id_token,
        scope = data.scope or "",
    }, nil
end

local function refresh_common(conf, refresh_token)
    local res, err = post_form(conf, host(conf) .. conf.token_path, {
        grant_type = "refresh_token",
        refresh_token = refresh_token,
        client_id = conf.client_id,
    })
    if not res then return nil, err end
    if res.status == 401 or res.status == 403 then
        return nil, "invalid_grant"
    end
    if res.status >= 500 then
        return nil, "refresh server error (HTTP " .. res.status .. ")"
    end
    local token, tok_err = token_from_response(res, {
        require_refresh_token = conf.refresh_rotation_required ~= false,
        keep_refresh_token = conf.refresh_rotation_required == false and refresh_token or nil,
    })
    if not token then return nil, "refresh failed: " .. tok_err end
    return token, nil
end

-- PKCE / state helpers (browser flows).
function M.generate_pkce()
    local verifier = base64url(random.bytes(32, true))
    local challenge = base64url(sha256_bin(verifier))
    return verifier, challenge
end

function M.generate_state()
    return base64url(random.bytes(32, true))
end

function M.browser_authorization_url(conf, redirect_uri, state, challenge)
    local params = {
        response_type = "code",
        client_id = conf.client_id,
        redirect_uri = redirect_uri,
        state = state,
        code_challenge = challenge,
        code_challenge_method = "S256",
    }
    for k, v in pairs(conf.authorize_params or {}) do
        params[k] = v
    end
    local parts = {}
    for key, value in pairs(params) do
        parts[#parts + 1] = url_encode(key) .. "=" .. url_encode(value)
    end
    return host(conf) .. conf.authorize_path .. "?" .. table.concat(parts, "&")
end

function M.exchange_browser_code(conf, code, redirect_uri, verifier)
    local res, err = post_form(conf, host(conf) .. conf.token_path, {
        grant_type = "authorization_code",
        code = code,
        redirect_uri = redirect_uri,
        client_id = conf.client_id,
        code_verifier = verifier,
    })
    if not res then return nil, err end
    if res.status < 200 or res.status >= 300 then
        return nil, "browser token exchange failed (HTTP " .. res.status .. ")"
    end
    local token, tok_err = token_from_response(res, { require_refresh_token = true })
    if not token then return nil, "browser token exchange: " .. tok_err end
    return token, nil
end

local engines = {}

-- RFC 8628: single token endpoint for device grant + refresh; pending and
-- expiry are OAuth error codes in the response body.
engines.rfc8628 = {}
function engines.rfc8628.request_device_authorization(conf)
    local res, err = post_auto(conf, host(conf) .. conf.device_authorize_path, {
        client_id = conf.client_id,
    })
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

function engines.rfc8628.poll_device_token(conf, device_code)
    local res, err = post_auto(conf, host(conf) .. conf.token_path, {
        client_id = conf.client_id,
        device_code = device_code,
        grant_type = "urn:ietf:params:oauth:grant-type:device_code",
    })
    if not res then return nil, err end

    if res.status == 200 then
        local token, tok_err = token_from_response(res, { require_refresh_token = true })
        if not token then return nil, tok_err end
        return token, nil
    end

    if res.status >= 500 then
        return nil, "token polling server error (HTTP " .. res.status .. ")"
    end

    local error_code = type(res.data.error) == "string" and res.data.error or "unknown_error"
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

engines.rfc8628.refresh_access_token = refresh_common

-- ChatGPT/Codex custom device flow: JSON usercode endpoint mints a
-- device_auth_id; polling exchanges it for an authorization_code +
-- code_verifier, then a form POST to the standard token endpoint completes.
-- Pending is signalled by HTTP 403/404 instead of body error codes.
engines.chatgpt_device = {}
function engines.chatgpt_device.request_device_authorization(conf)
    local res, err = post_json(conf, host(conf) .. conf.device_authorize_path, {
        client_id = conf.client_id,
    })
    if not res then return nil, err end
    if res.status ~= 200 then
        return nil, "device authorization failed (HTTP " .. res.status .. ")"
    end
    local data = res.data
    if not data.device_auth_id or not data.user_code then
        return nil, "device authorization response missing device_auth_id or user_code"
    end
    return {
        device_code = data.device_auth_id,
        user_code = data.user_code,
        verification_uri = host(conf) .. conf.verification_path,
        verification_uri_complete = host(conf) .. conf.verification_path,
        interval = tonumber(data.interval) or 5,
        expires_in = tonumber(data.expires_in) or 900,
    }, nil
end

function engines.chatgpt_device.poll_device_token(conf, device_code, user_code)
    local res, err = post_json(conf, host(conf) .. conf.device_poll_path, {
        device_auth_id = device_code,
        user_code = user_code,
    })
    if not res then return nil, err end
    if res.status == 403 or res.status == 404 then
        return { pending = true, error_code = "authorization_pending" }, nil
    end
    if res.status ~= 200 then
        return nil, "device polling failed (HTTP " .. res.status .. ")"
    end
    if not res.data.authorization_code or not res.data.code_verifier then
        return nil, "device response missing authorization_code or code_verifier"
    end
    local exchange, ex_err = post_form(conf, host(conf) .. conf.token_path, {
        grant_type = "authorization_code",
        code = res.data.authorization_code,
        redirect_uri = host(conf) .. conf.device_callback_path,
        client_id = conf.client_id,
        code_verifier = res.data.code_verifier,
    })
    if not exchange then return nil, ex_err end
    if exchange.status < 200 or exchange.status >= 300 then
        return nil, "token exchange failed (HTTP " .. exchange.status .. ")"
    end
    local value, tok_err = token_from_response(exchange, { require_refresh_token = true })
    if not value then return nil, tok_err end
    return value, nil
end

engines.chatgpt_device.refresh_access_token = refresh_common

function M.engine(conf)
    return engines[conf.protocol or "rfc8628"] or engines.rfc8628
end

return M
