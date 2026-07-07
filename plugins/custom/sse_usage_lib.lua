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
    local done = false
    local usage, model
    local cost = 0
    for line in text:gmatch("[^\r\n]+") do
        local payload = line:match("^data:%s*(.+)$")
        if payload then
            if payload == "[DONE]" then
                done = true
            else
                local obj = cjson.decode(payload)
                if obj and type(obj) == "table" then
                    if obj.usage and type(obj.usage) == "table" then
                        usage = obj.usage
                        local ec = tonumber(obj.usage.estimated_cost)
                        if ec and ec > 0 then cost = ec end
                    end
                    if obj.model and type(obj.model) == "string" and obj.model ~= "" and not model then
                        model = obj.model
                    end
                    local chunk_cost = tonumber(obj.cost)
                    if chunk_cost and chunk_cost > 0 then
                        cost = chunk_cost
                    end
                end
            end
        end
    end
    return usage, model, done, cost
end

function M.parse_json_usage(body)
    local cjson = require("cjson.safe")
    local obj = cjson.decode(body)
    if not obj or type(obj) ~= "table" then return nil, nil, 0 end
    if obj.usage and type(obj.usage) == "table" then
        local cost = 0
        local ec = tonumber(obj.usage.estimated_cost)
        if ec and ec > 0 then cost = ec end
        local oc = tonumber(obj.cost)
        if oc and oc > 0 then cost = oc end
        return obj.usage, obj.model, cost
    end
    return nil, nil, 0
end

function M.extract_tokens(usage)
    if not usage then return 0, 0, 0, 0, 0 end
    local pt = tonumber(usage.prompt_tokens) or 0
    local ct = tonumber(usage.completion_tokens) or 0
    local tt = tonumber(usage.total_tokens) or 0
    local cached = 0
    local reasoning = 0
    if type(usage.prompt_tokens_details) == "table" then
        cached = tonumber(usage.prompt_tokens_details.cached_tokens) or 0
    end
    cached = tonumber(usage.cached_tokens) or cached
    reasoning = tonumber(usage.reasoning_tokens) or 0
    if type(usage.completion_tokens_details) == "table" then
        reasoning = tonumber(usage.completion_tokens_details.reasoning_tokens) or reasoning
    end
    return pt, ct, tt, cached, reasoning
end

return M
