local M = {}

local function normalize_usage(usage)
    if type(usage) ~= "table" then return nil end
    if usage.prompt_tokens or usage.completion_tokens then return usage end
    if usage.input_tokens or usage.output_tokens then
        local normalized = {
            prompt_tokens = usage.input_tokens or 0,
            completion_tokens = usage.output_tokens or 0,
            total_tokens = usage.total_tokens or ((usage.input_tokens or 0) + (usage.output_tokens or 0)),
        }
        local input_details = usage.input_tokens_details
        if type(input_details) == "table" then
            normalized.prompt_tokens_details = {
                cached_tokens = input_details.cached_tokens or input_details.cache_read_input_tokens or 0,
            }
        end
        local output_details = usage.output_tokens_details
        if type(output_details) == "table" then
            normalized.completion_tokens_details = {
                reasoning_tokens = output_details.reasoning_tokens or 0,
            }
        end
        return normalized
    end
    return usage
end

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
                    local response = type(obj.response) == "table" and obj.response or obj
                    if response.usage and type(response.usage) == "table" then
                        usage = normalize_usage(response.usage)
                        local ec = tonumber(response.usage.estimated_cost)
                        if ec and ec > 0 then cost = ec end
                    end
                    if response.model and type(response.model) == "string" and response.model ~= "" and not model then
                        model = response.model
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
        return normalize_usage(obj.usage), obj.model, cost
    end
    if type(obj.response) == "table" and type(obj.response.usage) == "table" then
        return normalize_usage(obj.response.usage), obj.response.model, tonumber(obj.cost) or 0
    end
    return nil, nil, 0
end

--Token counts come exclusively from upstream-reported usage fields. When the
--upstream does not report a dimension (e.g. reasoning_tokens) the value is 0;
--no estimation.
function M.extract_tokens(usage)
    if not usage then return 0, 0, 0, 0, 0 end
    usage = normalize_usage(usage)
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
