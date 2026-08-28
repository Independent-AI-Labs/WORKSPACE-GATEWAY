--Mock apisix.core before loading the module (matches test_provider_sync pattern).
package.loaded["apisix.core"] = {
    log = {
        warn = function(...) end,
        error = function(...) end,
    },
    request = {
        header = function(...) return nil end,
        get_body = function() return "{}" end,
    },
}
local session = require("oauth_session")

local function b64url(s)
    return ngx.encode_base64(s):gsub("=+$", ""):gsub("%+", "-"):gsub("/", "_")
end

local function jwt_with_exp(exp)
    local header = b64url('{"alg":"RS256","typ":"JWT"}')
    local payload = b64url('{"sub":"u1","exp":' .. exp .. "}")
    return header .. "." .. payload .. ".sig"
end

local now = ngx.time()

-- needs_refresh: JWT exp wins, stored expiry is the fallback, unknown is fail-closed.
assert(session.needs_refresh(jwt_with_exp(now + 3600), nil, 300) == false, "future JWT exp must not refresh")
assert(session.needs_refresh(jwt_with_exp(now + 60), nil, 300) == true, "near JWT exp must refresh")
assert(session.needs_refresh("opaque-token", now + 3600, 300) == false, "stored expiry must be honored")
assert(session.needs_refresh("opaque-token", now + 60, 300) == true, "near stored expiry must refresh")
assert(session.needs_refresh("opaque-token", nil, 300) == true, "unknown expiry must fail closed")
assert(session.needs_refresh("opaque-token", "garbage", 300) == true, "malformed stored expiry must fail closed")

-- ensure_fresh: fresh session passes through untouched.
local tokens = { deleted = 0, stored = 0, store_err = nil }
function tokens.delete_session() tokens.deleted = tokens.deleted + 1 end
function tokens.store_session() tokens.stored = tokens.stored + 1; if tokens.store_err then return nil, tokens.store_err end return true end

local conf = { refresh_threshold = 300 }
local opts = {
    prefix = "test-auth",
    refresh = function(_, _refresh_token) return nil, "boom" end,
    build_record = function(b, result, old)
        return { access_token = result.access_token, expires_at = result.expires_at,
                 issued_access_token_hash = old.issued_access_token_hash }
    end,
}

local access = session.ensure_fresh(conf, tokens, "client-token",
    { access_token = jwt_with_exp(now + 3600), expires_at = now + 3600 }, opts)
assert(access == jwt_with_exp(now + 3600), "fresh session must not refresh")

-- ensure_fresh: invalid_grant deletes the session and demands re-auth.
opts.refresh = function(_, _) return nil, "invalid_grant" end
local _, status, err = session.ensure_fresh(conf, tokens, "client-token",
    { access_token = "opaque", expires_at = now + 60, refresh_token = "rt" }, opts)
assert(status == 401 and err.error == "test-auth: re-authenticate", "invalid_grant must 401")
assert(tokens.deleted == 1, "invalid_grant must delete the session")

-- ensure_fresh: transient refresh failure is 503 without deleting.
opts.refresh = function(_, _) return nil, "http request failed" end
_, status, err = session.ensure_fresh(conf, tokens, "client-token",
    { access_token = "opaque", expires_at = now + 60, refresh_token = "rt" }, opts)
assert(status == 503 and err.error == "test-auth: token refresh failed", "transient failure must 503")
assert(tokens.deleted == 1, "transient failure must not delete")

-- ensure_fresh: refresh that cannot be persisted is terminal (503), never used.
opts.refresh = function(_, _) return { access_token = "new-access", expires_at = now + 3600 } end
tokens.store_err = "openbao returned status 500"
_, status, err = session.ensure_fresh(conf, tokens, "client-token",
    { access_token = "opaque", expires_at = now + 60, refresh_token = "rt",
      issued_access_token_hash = "orig" }, opts)
assert(status == 503 and err.error == "test-auth: cannot reach token store", "store failure must be terminal")
assert(tokens.stored == 1, "refresh must attempt one store")

-- ensure_fresh: successful refresh persists under the original client key.
tokens.store_err = nil
local new_access, updated = session.ensure_fresh(conf, tokens, "client-token",
    { access_token = "opaque", expires_at = now + 60, refresh_token = "rt",
      issued_access_token_hash = "orig" }, opts)
assert(new_access == "new-access" and updated.issued_access_token_hash == "orig",
    "refresh must keep the issued-hash key")
assert(tokens.stored == 2, "successful refresh must persist")

print("PASS: oauth session tests")
