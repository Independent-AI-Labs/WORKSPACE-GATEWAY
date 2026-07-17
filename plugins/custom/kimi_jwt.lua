local resty_sha256 = require("resty.sha256")

local M = {}

function M.token_hash(token)
    if not token or token == "" then return "" end
    local d = resty_sha256:new()
    d:update(token)
    local bin = d:final()
    local hex = {}
    for i = 1, #bin do
        hex[i] = string.format("%02x", string.byte(bin, i))
    end
    return table.concat(hex)
end

local function base64url_decode(value)
    if not value or value == "" then return nil end
    local pad = 4 - (#value % 4)
    if pad ~= 4 then
        value = value .. string.rep("=", pad)
    end
    value = value:gsub("-", "+"):gsub("_", "/")
    local ok, decoded = pcall(ngx.decode_base64, value)
    if not ok or not decoded then return nil end
    return decoded
end

function M.decode_claims(token)
    if not token or token == "" then return {} end
    local header, payload = token:match("^([^%.]+)%.([^%.]+)%.")
    if not payload then return {} end
    local decoded = base64url_decode(payload)
    if not decoded then return {} end
    local cjson = require("cjson.safe")
    local ok, claims = pcall(cjson.decode, decoded)
    if not ok or type(claims) ~= "table" then return {} end
    return claims
end

function M.expires_at(token)
    local claims = M.decode_claims(token)
    local exp = tonumber(claims.exp)
    if exp and exp > 0 then return exp end
    return nil
end

function M.is_expiring(token, threshold)
    local exp = M.expires_at(token)
    if not exp then return false end
    local now = ngx.time()
    return exp <= now + (threshold or 300)
end

function M.subject(token)
    local claims = M.decode_claims(token)
    return claims.sub or claims.user_id or claims.email or nil
end

return M
