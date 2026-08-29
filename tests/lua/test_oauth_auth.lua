--Unit tests for the generic oauth-auth plugin (mocked APISIX/OpenBao/http).
local set_headers = {}
local body_override = nil
local raw_body = "{}"

ngx.req = {
    set_header = function(k, v) set_headers[k] = v end,
    set_body_data = function(b) body_override = b end,
    get_body_data = function() return body_override end,
}
ngx.var = { arg_session = "test-session", request_id = "req-test" }

--The resty CLI lacks ngx.sha256_bin (APISIX runtime has it via lua-resty-core).
if not ngx.sha256_bin then
    local sha256 = require("resty.sha256")
    ngx.sha256_bin = function(s)
        local digest = sha256:new()
        digest:update(s)
        return digest:final()
    end
end

local store_calls = { store_session = 0, store_device = 0, delete_device = 0,
    delete_session = 0, consume_device = 0 }
local stored_sessions = {}
local stored_devices = {}
local session_for_bearer = nil
local device_for_code = nil

local fake_store = {}
function fake_store.store_session(_, bearer, record)
    store_calls.store_session = store_calls.store_session + 1
    stored_sessions[bearer] = record
    return true
end
function fake_store.load_session_by_bearer(_, _bearer)
    return session_for_bearer
end
function fake_store.delete_session(_, _bearer)
    store_calls.delete_session = store_calls.delete_session + 1
    return true
end
function fake_store.store_device(_, code, record)
    store_calls.store_device = store_calls.store_device + 1
    stored_devices[code] = record
    return true
end
function fake_store.load_device(_, code)
    if device_for_code then return device_for_code end
    return stored_devices[code]
end
function fake_store.delete_device(_, _code)
    store_calls.delete_device = store_calls.delete_device + 1
    return true
end
function fake_store.consume_device(_, code)
    store_calls.consume_device = store_calls.consume_device + 1
    return stored_devices[code]
end

package.loaded["apisix.core"] = {
    log = { warn = function() end, error = function() end },
    request = {
        header = function(ctx, name)
            return (ctx and ctx.headers or {})[name]
        end,
        get_body = function() return raw_body end,
    },
    schema = { check = function() return true end },
}
package.loaded["apisix.plugins.oauth_store"] = fake_store
package.loaded["apisix.plugins.oauth_jwt"] = require("oauth_jwt")

--Script resty.http for oauth_device engine calls.
local http_queue = {}
package.loaded["resty.http"] = {
    new = function()
        return {
            set_timeout = function() end,
            request_uri = function(_, url, opts)
                local reply = #http_queue > 0 and table.remove(http_queue, 1)
                    or { status = 500, data = {} }
                return { status = reply.status,
                    body = require("cjson.safe").encode(reply.data or {}) }, nil
            end,
        }
    end,
}
package.loaded["apisix.plugins.oauth_device"] = require("oauth_device")

local plugin = dofile("/plugins/custom/oauth-auth.lua")

local pass = 0
local fail = 0
local function check(cond, msg)
    if cond then pass = pass + 1 else fail = fail + 1
        io.stderr:write("[FAIL] " .. msg .. "\n") end
end

local function b64url(s)
    return ngx.encode_base64(s):gsub("=+$", ""):gsub("%+", "-"):gsub("/", "_")
end
local function make_jwt(payload)
    return b64url('{"alg":"none"}') .. "." .. b64url(require("cjson.safe").encode(payload)) .. "."
end

local now = ngx.time()
local conf = {
    auth_base = "/test/auth",
    protocol = "rfc8628",
    oauth_host = "https://auth.example.com",
    client_id = "cid",
    device_authorize_path = "/da",
    token_path = "/tok",
    token_prefix = "secret/data/gateway/test-tokens/",
    device_prefix = "secret/data/gateway/test-device/",
    reject_key_prefix = "sk-",
    reject_key_pointer = "/test-key",
    strip_request_fields = { "max_output_tokens" },
    fixed_upstream_headers = { originator = "opencode" },
    alias_headers = { ["X-OpenCode-Session-Id"] = "session-id" },
    account_claim_paths = {
        { claim = "chatgpt_account_id" },
        { claim = "organizations", index = 1, field = "id" },
    },
    account_header = "ChatGPT-Account-Id",
    refresh_threshold = 300,
}

local function call(uri, headers)
    local ctx = { var = { uri = uri }, headers = headers or {} }
    set_headers = {}
    body_override = nil
    local status, body = plugin.access(conf, ctx)
    return status, body, ctx
end

-- Device start: brokers upstream code and stores the pending record.
http_queue[1] = { status = 200, data = { user_code = "UC", device_code = "up-1",
    verification_uri = "https://auth.example.com/v", expires_in = 900, interval = 5 } }
local status = call("/test/auth/device")
check(status == 200, "device start returns 200")
local gw_codes = {}
for code, _ in pairs(stored_devices) do gw_codes[#gw_codes + 1] = code end
check(#gw_codes == 1 and gw_codes[1]:sub(1, 3) == "gw-", "device start stores gw- prefixed code")
check(stored_devices[gw_codes[1]].user_code == "UC", "device record keeps user_code")

-- Device poll: missing device_code is 400.
local ret = call("/test/auth/device/poll")
check(select("#", ret) >= 1 and select(1, ret) == 400, "poll missing device_code is 400")

-- Device poll: success stores session, deletes pending, returns token.
device_for_code = { device_code = "up-1", session_id = "sess-1",
    expires_at = now + 600, user_code = "UC" }
http_queue[1] = { status = 200, data = { access_token = "at-1", refresh_token = "rt-1",
    expires_in = 3600 } }
raw_body = require("cjson.safe").encode({ device_code = "gw-x" })
local status, body = call("/test/auth/device/poll")
check(status == 200 and body.access_token == "at-1", "poll success returns access_token")
check(body.session_id == "sess-1", "poll success returns session_id")
check(store_calls.delete_device >= 1, "poll success deletes pending record")
check(stored_sessions["at-1"] ~= nil, "poll success stores session under issued token")

-- Proxy: missing bearer is 401.
status, body = call("/test/api/chat")
check(status == 401 and body.error:find("missing Authorization", 1, true), "proxy missing bearer 401")

-- Proxy: rejected key prefix points at the passthrough route.
status, body = call("/test/api/chat", { Authorization = "Bearer sk-user-key" })
check(status == 401 and body.error:find("/test-key", 1, true), "proxy sk- rejected with pointer")

-- Proxy: unknown session is 401 with re-auth hint.
status, body = call("/test/api/chat", { Authorization = "Bearer unknown-token" })
check(status == 401 and body.error:find("session not found", 1, true), "proxy unknown session 401")

-- Proxy happy path: fresh session, no refresh, headers injected.
local fresh_jwt = make_jwt({ sub = "user-9", exp = now + 3600 })
session_for_bearer = { access_token = fresh_jwt, refresh_token = "rt-1",
    expires_at = now + 3600, issued_access_token_hash = "aaaaaaaaaaaaaaaa",
    sub = "user-9", session_id = "sess-1", account_id = "acct-7" }
local ret2, _, ctx2 = call("/test/api/chat", {
    Authorization = "Bearer " .. fresh_jwt,
    ["X-OpenCode-Session-Id"] = "opencode-sess",
})
check(ret2 == nil, "proxy fresh session continues (no exit)")
check(set_headers["Authorization"] == "Bearer " .. fresh_jwt, "proxy injects fresh bearer")
check(set_headers["X-Gateway-Key-Id"] == "aaaaaaaaaaaaaaaa", "proxy key id from issued hash")
check(set_headers["X-Gateway-User-Id"] == "user-9", "proxy user id from sub")
check(set_headers["X-Gateway-Tenant-Id"] == "sess-1", "proxy tenant from session_id")
check(set_headers["originator"] == "opencode", "proxy fixed header injected")
check(set_headers["ChatGPT-Account-Id"] == "acct-7", "proxy account header injected")
check(set_headers["session-id"] == "opencode-sess", "proxy alias header forwarded")
check(ctx2.consumer and ctx2.consumer.username == "aaaaaaaaaaaaaaaa", "consumer username set")

-- Proxy: strip_request_fields removes configured fields from the body.
raw_body = require("cjson.safe").encode({ model = "m", max_output_tokens = 10 })
session_for_bearer.access_token = fresh_jwt
call("/test/api/chat", { Authorization = "Bearer " .. fresh_jwt })
local parsed = require("cjson.safe").decode(body_override or raw_body)
check(parsed ~= nil and parsed.model == "m" and parsed.max_output_tokens == nil,
    "strip_request_fields removes configured field")

-- Proxy: near-expiry triggers refresh via the engine and injects the new token.
local expiring_jwt = make_jwt({ sub = "user-9", exp = now + 60 })
session_for_bearer = { access_token = expiring_jwt, refresh_token = "rt-1",
    expires_at = now + 60, issued_access_token_hash = "aaaaaaaaaaaaaaaa",
    sub = "user-9", session_id = "sess-1", account_id = "acct-7" }
http_queue[1] = { status = 200, data = { access_token = "at-refreshed", refresh_token = "rt-2",
    expires_in = 3600 } }
ret2 = call("/test/api/chat", { Authorization = "Bearer " .. expiring_jwt })
check(ret2 == nil, "refreshed proxy continues")
check(set_headers["Authorization"] == "Bearer at-refreshed", "refreshed bearer injected")
check(stored_sessions[expiring_jwt] ~= nil
    and stored_sessions[expiring_jwt].issued_access_token_hash == "aaaaaaaaaaaaaaaa",
    "refresh persists under original issued hash")

-- Refresh persistence failure is terminal (503), token never issued.
local expiring2 = make_jwt({ sub = "u", exp = now + 60 })
session_for_bearer = { access_token = expiring2, refresh_token = "rt-x",
    expires_at = now + 60, issued_access_token_hash = "bbbb" }
http_queue[1] = { status = 200, data = { access_token = "at-dead", refresh_token = "rt-y",
    expires_in = 3600 } }
local real_store_session = fake_store.store_session
fake_store.store_session = function() return nil, "openbao down" end
status, body = call("/test/api/chat", { Authorization = "Bearer " .. expiring2 })
check(status == 503, "unpersisted refresh is terminal 503")
fake_store.store_session = real_store_session

-- Browser endpoints are gated off without browser_flow.
conf.browser_flow = false
status, body = call("/test/auth/browser", {})
check(status == 401, "browser endpoint gated off without browser_flow")

-- Browser flow start + callback happy path.
conf.browser_flow = true
conf.authorize_path = "/oauth/authorize"
conf.authorize_params = { originator = "opencode" }
raw_body = "{}"
status, body = call("/test/auth/browser")
check(status == 200 and body.authorization_url ~= nil and body.state ~= nil,
    "browser start returns authorization URL")
local browser_state = body.state
check(stored_devices[browser_state] ~= nil
    and stored_devices[browser_state].code_verifier ~= nil, "browser state stores verifier")

local id_token = make_jwt({ chatgpt_account_id = "acct-from-idtoken" })
http_queue[1] = { status = 200, data = { access_token = "at-browser", refresh_token = "rt-b",
    expires_in = 3600, id_token = id_token } }
raw_body = require("cjson.safe").encode({ state = browser_state, code = "auth-code" })
status, body = call("/test/auth/browser/callback")
check(status == 200 and body.access_token == "at-browser", "browser callback returns token")
check(stored_sessions["at-browser"] ~= nil
    and stored_sessions["at-browser"].account_id == "acct-from-idtoken",
    "account claim resolved from id_token claim path")

-- claim path: nested organizations[1].id fallback.
local org_token = make_jwt({ organizations = { { id = "org-77" } } })
local record = { access_token = "t", refresh_token = "r", expires_in = 60 }
local resolved = nil
-- exercise via poll: engine result with id_token carrying org claim
device_for_code = { device_code = "up-2", session_id = "s2", expires_at = now + 600, user_code = "U" }
http_queue[1] = { status = 200, data = { access_token = "at-org", refresh_token = "rt-o",
    expires_in = 3600, id_token = org_token } }
raw_body = require("cjson.safe").encode({ device_code = "gw-org" })
status, body = call("/test/auth/device/poll")
check(status == 200 and stored_sessions["at-org"] ~= nil
    and stored_sessions["at-org"].account_id == "org-77",
    "account claim resolves via organizations[1].id path")

if fail > 0 then
    io.stderr:write("test_oauth_auth: " .. fail .. " failed\n")
    os.exit(1)
end
print("test_oauth_auth: " .. pass .. " passed")
