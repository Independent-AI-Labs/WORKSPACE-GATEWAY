-- Shared OAuth session behavior for kimi-auth and openai-auth.
-- Only identical session/refresh/header logic lives here; provider protocol
-- differences stay in kimi_device.lua / openai_device.lua and the plugins.
local core = require("apisix.core")
local cjson = require("cjson.safe")
local ok, jwt = pcall(require, "apisix.plugins.kimi_jwt")
if not ok then
    jwt = require("kimi_jwt")
end

local M = {}

function M.bearer(ctx)
    local value = core.request.header(ctx, "Authorization")
    if type(value) == "table" then value = value[1] end
    return value and value:match("^%s*[Bb]earer%s+(.+)%s*$")
end

function M.json_body()
    local raw = core.request.get_body() or "{}"
    if type(raw) == "table" then raw = raw[1] or "{}" end
    local parsed_ok, parsed = pcall(cjson.decode, raw)
    if not parsed_ok or type(parsed) ~= "table" then return {} end
    return parsed
end

-- Effective expiry prefers the JWT exp claim and falls back to the stored
-- session expires_at. Unknown expiry (neither present) must refresh: failing
-- closed self-heals the session instead of trusting an unexpiring token.
function M.needs_refresh(access_token, stored_expires_at, threshold)
    local exp = jwt.expires_at(access_token)
    if not exp then
        local stored = tonumber(stored_expires_at)
        if not stored or stored <= 0 then return true end
        exp = stored
    end
    return exp <= ngx.time() + (threshold or 300)
end

-- Refresh and persist. Persistence failure is terminal: a rotated refresh
-- token that is not durably stored would make the next request (and the
-- client's stored credential) permanently unusable.
-- opts = { prefix, refresh(conf, refresh_token), build_record(bearer, result, session) }
-- Returns access_token, session_record | nil, status, err_body
function M.ensure_fresh(conf, tokens, bearer_value, session, opts)
    local access = session.access_token
    if not M.needs_refresh(access, session.expires_at, conf.refresh_threshold) then
        return access, session
    end
    local refreshed, err = opts.refresh(conf, session.refresh_token)
    if not refreshed then
        if err == "invalid_grant" then
            tokens.delete_session(conf, bearer_value)
            return nil, 401, { error = opts.prefix .. ": re-authenticate" }
        end
        core.log.error(opts.prefix, ": token refresh failed: ", err or "unknown")
        return nil, 503, { error = opts.prefix .. ": token refresh failed" }
    end
    local updated = opts.build_record(bearer_value, refreshed, session)
    local _, store_err = tokens.store_session(conf, bearer_value, updated)
    if store_err then
        core.log.error(opts.prefix, ": refreshed session not persisted, refusing token: ", store_err)
        return nil, 503, { error = opts.prefix .. ": cannot reach token store" }
    end
    return refreshed.access_token, updated
end

function M.set_meta_headers(key_id, user_id, tenant_id)
    ngx.req.set_header("X-Gateway-Key-Id", key_id)
    ngx.req.set_header("X-Gateway-User-Id", user_id)
    ngx.req.set_header("X-Gateway-Tenant-Id", tenant_id)
    ngx.req.set_header("X-Gateway-Rate-Limit-RPM", "100")
    ngx.req.set_header("X-Gateway-Rate-Limit-Window", "60")
end

return M
