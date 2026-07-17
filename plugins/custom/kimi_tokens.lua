local core = require("apisix.core")
local cjson = require("cjson.safe")
local http = require("resty.http")
local jwt = require("apisix.plugins.kimi_jwt")

local M = {}

local function openbao_token(conf)
    return os.getenv(conf.openbao_token_env)
end

local function bao_request(conf, method, path, body)
    local token = openbao_token(conf)
    if not token or token == "" then
        return nil, "openbao token env var not set: " .. conf.openbao_token_env
    end

    local url = conf.openbao_addr:gsub("/$", "") .. "/v1/" .. path
    local headers = { ["X-Vault-Token"] = token }
    local req_body
    if body then
        req_body = cjson.encode(body)
        headers["Content-Type"] = "application/json"
    end

    local httpc = http.new()
    local res, err = httpc:request_uri(url, {
        method = method,
        headers = headers,
        body = req_body,
        timeout = 5000,
        ssl_verify = false,
    })

    if not res then
        return nil, "openbao request failed: " .. (err or "unknown")
    end
    if res.status == 404 then
        return nil, "not found"
    end
    if res.status ~= 200 and res.status ~= 204 then
        return nil, "openbao returned status " .. res.status .. ": " .. (res.body or "")
    end
    return res, nil
end

local function unwrap_kv_data(res)
    if not res or not res.body or res.body == "" then return nil end
    local data = cjson.decode(res.body)
    if not data or not data.data or not data.data.data then
        return nil
    end
    return data.data.data
end

function M.store_device(conf, device_code, record)
    local hash = jwt.token_hash(device_code)
    local path = conf.device_prefix .. hash
    return bao_request(conf, "POST", path, { data = record })
end

function M.load_device(conf, device_code)
    local hash = jwt.token_hash(device_code)
    local path = conf.device_prefix .. hash
    local res, err = bao_request(conf, "GET", path)
    if not res then return nil, err end
    return unwrap_kv_data(res), nil
end

function M.delete_device(conf, device_code)
    local hash = jwt.token_hash(device_code)
    local path = conf.device_prefix .. hash
    local res, err = bao_request(conf, "DELETE", path)
    if not res and err and err:find("not found") then
        return true, nil
    end
    return res ~= nil, err
end

function M.store_session(conf, bearer, record)
    local hash = jwt.token_hash(bearer)
    local path = conf.token_prefix .. hash
    return bao_request(conf, "POST", path, { data = record })
end

function M.load_session_by_bearer(conf, bearer)
    local hash = jwt.token_hash(bearer)
    local path = conf.token_prefix .. hash
    local res, err = bao_request(conf, "GET", path)
    if not res then return nil, err end
    return unwrap_kv_data(res), nil
end

function M.delete_session(conf, bearer)
    local hash = jwt.token_hash(bearer)
    local path = conf.token_prefix .. hash
    local res, err = bao_request(conf, "DELETE", path)
    if not res and err and err:find("not found") then
        return true, nil
    end
    return res ~= nil, err
end

return M
