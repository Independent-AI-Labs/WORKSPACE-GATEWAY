local M = {}

function M.buffer_chunk(existing, new_chunk)
    if type(new_chunk) ~= "string" or new_chunk == "" then
        return "", existing or ""
    end
    local buf = (existing or "") .. new_chunk
    local last_nl = nil
    for i = #buf, 1, -1 do
        if buf:byte(i) == 10 then
            last_nl = i
            break
        end
    end
    if not last_nl then
        return "", buf
    end
    local complete = buf:sub(1, last_nl)
    local remainder = buf:sub(last_nl + 1)
    return complete, remainder
end

function M.scan_sse_for_usage(text)
    local cjson = require("cjson.safe")
    for line in text:gmatch("[^\r\n]+") do
        local payload = line:match("^data:%s*(.+)$")
        if payload and payload ~= "[DONE]" then
            local obj = cjson.decode(payload)
            if obj and type(obj) == "table" and obj.usage ~= nil and type(obj.usage) == "table" then
                return obj.usage, obj.model
            end
        end
    end
    return nil, nil
end

function M.parse_json_usage(body)
    local cjson = require("cjson.safe")
    local obj = cjson.decode(body)
    if not obj or type(obj) ~= "table" then return nil, nil end
    if obj.usage and type(obj.usage) == "table" then
        return obj.usage, obj.model
    end
    return nil, nil
end

function M.extract_tokens(usage)
    if not usage then return 0, 0, 0 end
    local pt = tonumber(usage.prompt_tokens) or 0
    local ct = tonumber(usage.completion_tokens) or 0
    local tt = tonumber(usage.total_tokens) or 0
    return pt, ct, tt
end

return M
