--Mock resty.http before loading oauth_device (matches test_oauth_session pattern).
local calls = {}
local queue = {}
local standing = { status = 500, data = {} }
local cjson = require("cjson.safe")

package.loaded["resty.http"] = {
    new = function()
        return {
            set_timeout = function() end,
            request_uri = function(_, url, opts)
                calls[#calls + 1] = { url = url, opts = opts }
                local reply = #queue > 0 and table.remove(queue, 1) or standing
                return { status = reply.status, body = cjson.encode(reply.data or {}) }, nil
            end,
        }
    end,
}
local function set_reply(reply) standing = reply end
local function push(reply) queue[#queue + 1] = reply end

--The resty CLI lacks ngx.sha256_bin (present in the APISIX runtime via
--lua-resty-core); provide it from lua-resty-string for PKCE tests.
if not ngx.sha256_bin then
    local sha256 = require("resty.sha256")
    ngx.sha256_bin = function(s)
        local digest = sha256:new()
        digest:update(s)
        return digest:final()
    end
end

local device = require("oauth_device")

local pass = 0
local fail = 0
local function check(cond, msg)
    if cond then pass = pass + 1 else fail = fail + 1
        io.stderr:write("[FAIL] " .. msg .. "\n") end
end

local kimi_conf = {
    protocol = "rfc8628",
    oauth_host = "https://auth.example.com",
    client_id = "client-abc",
    user_agent = "TestAgent/1.0",
    device_authorize_path = "/api/oauth/device_authorization",
    token_path = "/api/oauth/token",
    ssl_verify = true,
}

local chatgpt_conf = {
    protocol = "chatgpt_device",
    oauth_host = "https://auth.example.com",
    client_id = "app_xyz",
    user_agent = "opencode/1.18.3",
    device_authorize_path = "/api/accounts/deviceauth/usercode",
    device_poll_path = "/api/accounts/deviceauth/token",
    device_callback_path = "/deviceauth/callback",
    verification_path = "/codex/device",
    token_path = "/oauth/token",
    refresh_rotation_required = false,
}

-- rfc8628: device authorization request shape and response parsing.
set_reply({ status = 200, data = {
    user_code = "WDJB-MJFF", device_code = "dc-1",
    verification_uri = "https://auth.example.com/device",
    verification_uri_complete = "https://auth.example.com/device?code=WDJB-MJFF",
    expires_in = 900, interval = 5,
} })
local auth = device.engine(kimi_conf).request_device_authorization(kimi_conf)
check(auth.user_code == "WDJB-MJFF", "rfc8628 user_code parsed")
check(auth.device_code == "dc-1", "rfc8628 device_code parsed")
check(calls[#calls].url == "https://auth.example.com/api/oauth/device_authorization", "rfc8628 authorize URL")
check(calls[#calls].opts.body == "client_id=client-abc", "rfc8628 authorize form body")
check(calls[#calls].opts.headers["User-Agent"] == "TestAgent/1.0", "rfc8628 UA from conf")
check(calls[#calls].opts.headers["Content-Type"] == "application/x-www-form-urlencoded", "rfc8628 form encoding")

-- rfc8628: pending, slow_down, expired, denied mapping.
set_reply({ status = 400, data = { error = "authorization_pending" } })
local r = device.engine(kimi_conf).poll_device_token(kimi_conf, "dc-1")
check(r.pending == true and r.error_code == "authorization_pending", "rfc8628 pending mapped")
set_reply({ status = 429, data = { error = "slow_down" } })
r = device.engine(kimi_conf).poll_device_token(kimi_conf, "dc-1")
check(r.pending == true and r.error_code == "slow_down", "rfc8628 slow_down mapped")
set_reply({ status = 400, data = { error = "expired_token" } })
r = device.engine(kimi_conf).poll_device_token(kimi_conf, "dc-1")
check(r.expired == true, "rfc8628 expired mapped")
set_reply({ status = 400, data = { error = "access_denied" } })
local _, err_msg = device.engine(kimi_conf).poll_device_token(kimi_conf, "dc-1")
check(err_msg == "authorization denied", "rfc8628 denied error")

-- rfc8628: success requires refresh_token + expires_in.
set_reply({ status = 200, data = { access_token = "at", refresh_token = "rt", expires_in = 3600 } })
r = device.engine(kimi_conf).poll_device_token(kimi_conf, "dc-1")
check(r.access_token == "at" and r.refresh_token == "rt" and r.expires_in == 3600, "rfc8628 token success shape")
check(calls[#calls].opts.body:find("device_code=dc-1", 1, true) ~= nil, "rfc8628 device grant body")
check(calls[#calls].opts.body:find("grant_type=urn", 1, true) ~= nil, "rfc8628 grant type present")
set_reply({ status = 200, data = { access_token = "at", expires_in = 3600 } })
_, err_msg = device.engine(kimi_conf).poll_device_token(kimi_conf, "dc-1")
check(err_msg == "token response missing refresh_token", "rfc8628 missing refresh_token rejected")

-- rfc8628 refresh: 401 maps to invalid_grant; success shape.
set_reply({ status = 401, data = { error = "invalid_grant" } })
_, err_msg = device.engine(kimi_conf).refresh_access_token(kimi_conf, "rt")
check(err_msg == "invalid_grant", "refresh 401 maps to invalid_grant")
set_reply({ status = 200, data = { access_token = "at2", refresh_token = "rt2", expires_in = 60 } })
r = device.engine(kimi_conf).refresh_access_token(kimi_conf, "rt")
check(r.access_token == "at2" and r.refresh_token == "rt2", "rfc8628 refresh success")

-- chatgpt_device: usercode parsing + synthesized verification URI.
set_reply({ status = 200, data = { device_auth_id = "da-9", user_code = "CODE", interval = 3 } })
auth = device.engine(chatgpt_conf).request_device_authorization(chatgpt_conf)
check(auth.device_code == "da-9" and auth.user_code == "CODE", "chatgpt usercode parsed")
check(auth.verification_uri == "https://auth.example.com/codex/device", "chatgpt verification URI from conf")
check(calls[#calls].opts.headers["Content-Type"] == "application/json", "chatgpt usercode JSON encoding")
check(calls[#calls].opts.body == '{"client_id":"app_xyz"}', "chatgpt usercode body")

-- chatgpt_device: 403/404 pending; two-step exchange on success (FIFO queue).
set_reply({ status = 403, data = {} })
r = device.engine(chatgpt_conf).poll_device_token(chatgpt_conf, "da-9", "CODE")
check(r.pending == true, "chatgpt 403 pending")
set_reply({ status = 404, data = {} })
r = device.engine(chatgpt_conf).poll_device_token(chatgpt_conf, "da-9", "CODE")
check(r.pending == true, "chatgpt 404 pending")

push({ status = 200, data = { authorization_code = "ac-1", code_verifier = "cv-1" } })
push({ status = 200, data = { access_token = "at9", refresh_token = "rt9", expires_in = 3600 } })
r = device.engine(chatgpt_conf).poll_device_token(chatgpt_conf, "da-9", "CODE")
check(r ~= nil and r.access_token == "at9" and r.refresh_token == "rt9", "chatgpt two-step token success")
check(calls[#calls].url == "https://auth.example.com/oauth/token", "chatgpt exchange hits token_path")
check(calls[#calls].opts.body:find("code_verifier=cv-1", 1, true) ~= nil, "chatgpt exchange carries verifier")
check(calls[#calls].opts.body:find("redirect_uri=https%3A%2F%2Fauth.example.com%2Fdeviceauth%2Fcallback", 1, true) ~= nil,
    "chatgpt exchange redirect_uri from conf")

-- chatgpt_device refresh: missing refresh_token tolerated when rotation not required.
set_reply({ status = 200, data = { access_token = "at10", expires_in = 60 } })
r = device.engine(chatgpt_conf).refresh_access_token(chatgpt_conf, "rt-old")
check(r.access_token == "at10" and r.refresh_token == "rt-old", "chatgpt refresh keeps old refresh_token")
-- ...but required when rotation IS required (default).
local strict = { protocol = "rfc8628", oauth_host = "https://a", client_id = "c",
    device_authorize_path = "/d", token_path = "/t" }
set_reply({ status = 200, data = { access_token = "at10", expires_in = 60 } })
_, err_msg = device.engine(strict).refresh_access_token(strict, "rt-old")
check(err_msg == "refresh failed: token response missing refresh_token", "strict refresh rejects missing rotation")

-- JSON encoding knob on the rfc8628 engine.
local json_conf = { protocol = "rfc8628", request_encoding = "json",
    oauth_host = "https://a", client_id = "c",
    device_authorize_path = "/d", token_path = "/t" }
set_reply({ status = 200, data = { user_code = "U", device_code = "D", expires_in = 90, interval = 2 } })
auth = device.engine(json_conf).request_device_authorization(json_conf)
check(auth.device_code == "D", "rfc8628 json encoding authorize parses")
check(calls[#calls].opts.headers["Content-Type"] == "application/json", "rfc8628 json encoding content type")

-- PKCE helpers.
local verifier, challenge = device.generate_pkce()
check(#verifier >= 40, "pkce verifier length")
check(#challenge >= 40, "pkce challenge length")
check(#device.generate_state() >= 40, "state length")

-- Browser URL merges authorize_params and carries PKCE + state.
local browser_conf = {
    oauth_host = "https://auth.example.com",
    client_id = "c1",
    authorize_path = "/oauth/authorize",
    authorize_params = { scope = "openid", originator = "opencode" },
}
local url = device.browser_authorization_url(browser_conf, "http://localhost:1455/auth/callback", "st-1", "ch-1")
check(url:find("^https://auth%.example%.com/oauth/authorize%?", 1) ~= nil, "browser URL base + path")
check(url:find("code_challenge=ch%-1", 1) ~= nil, "browser URL challenge")
check(url:find("state=st%-1", 1) ~= nil, "browser URL state")
check(url:find("scope=openid", 1) ~= nil and url:find("originator=opencode", 1) ~= nil, "browser URL extra params")
check(url:find("code_challenge_method=S256", 1) ~= nil, "browser URL S256")

-- engine() default and unknown fallback.
check(device.engine({}).refresh_access_token ~= nil, "engine default rfc8628")
check(device.engine({ protocol = "bogus" }) == device.engine({}), "engine unknown falls back")

if fail > 0 then
    io.stderr:write("test_oauth_device: " .. fail .. " failed\n")
    os.exit(1)
end
print("test_oauth_device: " .. pass .. " passed")
