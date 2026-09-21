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
        --Anthropic reports cache tokens as separate top-level counts that
        --input_tokens EXCLUDES (OpenAI totals include the cached subset).
        --Fold into the inclusive convention the extractor and cost formula
        --expect: total input covers reads + writes; cached_tokens carries the
        --read side and cache_write_tokens the write side, so each bills at its
        --own rate instead of writes being charged at the input rate.
        local cache_read = tonumber(usage.cache_read_input_tokens) or 0
        local cache_write = tonumber(usage.cache_creation_input_tokens) or 0
        if cache_read > 0 or cache_write > 0 then
            normalized.prompt_tokens = (usage.input_tokens or 0) + cache_read + cache_write
            normalized.total_tokens = normalized.prompt_tokens + normalized.completion_tokens
            normalized.prompt_tokens_details = {
                cached_tokens = (normalized.prompt_tokens_details
                    and normalized.prompt_tokens_details.cached_tokens or 0) + cache_read,
            }
            if cache_write > 0 then
                normalized.cache_write_tokens = cache_write
            end
        end
        return normalized
    end
    return usage
end

--Anthropic splits final counts across events (message_start carries the
--input side, message_delta the final output); OpenAI repeats running
--totals. Taking the larger of each dimension lands on the final totals
--under both conventions.
M.normalize_usage = normalize_usage
local function merge_usage(dst, src)
    if not dst then return src end
    local merged = {
        prompt_tokens = math.max(tonumber(dst.prompt_tokens) or 0, tonumber(src.prompt_tokens) or 0),
        completion_tokens = math.max(tonumber(dst.completion_tokens) or 0, tonumber(src.completion_tokens) or 0),
    }
    --total is defined as input + output in every supported convention, so
    --derive it after the merge; max() alone cannot recombine a split pair.
    merged.total_tokens = merged.prompt_tokens + merged.completion_tokens
    local function detail_value(u, key, field)
        local d = u[key]
        if type(d) == "table" then return tonumber(d[field]) or 0 end
        return 0
    end
    local cached = math.max(
        detail_value(dst, "prompt_tokens_details", "cached_tokens"),
        detail_value(src, "prompt_tokens_details", "cached_tokens"))
    if cached > 0 then
        merged.prompt_tokens_details = { cached_tokens = cached }
    end
    local reasoning = math.max(
        detail_value(dst, "completion_tokens_details", "reasoning_tokens"),
        detail_value(src, "completion_tokens_details", "reasoning_tokens"))
    if reasoning > 0 then
        merged.completion_tokens_details = { reasoning_tokens = reasoning }
    end
    local cache_write = math.max(
        tonumber(dst.cache_write_tokens) or 0,
        tonumber(src.cache_write_tokens) or 0)
    if cache_write > 0 then
        merged.cache_write_tokens = cache_write
    end
    return merged
end
M.merge_usage = merge_usage

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

--True when the event carries visible/reasoning text (chat-completions
--delta.content / delta.reasoning_content, or Responses-API *.delta frames
--with non-empty delta). Used by sse-usage to stamp ttft_content_ms.
local function event_has_content(obj)
    local choices = type(obj.choices) == "table" and obj.choices[1]
    if type(choices) == "table" and type(choices.delta) == "table" then
        local c = choices.delta.content
        if type(c) == "string" and c ~= "" then return true end
        local rc = choices.delta.reasoning_content
        if type(rc) == "string" and rc ~= "" then return true end
    end
    local et = type(obj.type) == "string" and obj.type or ""
    if et:sub(-6) == ".delta" or et == "content_block_delta" then
        local d = obj.delta
        if type(d) == "string" and d ~= "" then return true end
        --Anthropic content_block_delta: delta is a table carrying .text
        if type(d) == "table" and type(d.text) == "string" and d.text ~= "" then return true end
    end
    return false
end

function M.scan_sse_for_usage(text)
    local cjson = require("cjson.safe")
    local done = false
    local usage, model
    local cost = 0
    local has_content = false
    for line in text:gmatch("[^\r\n]+") do
        local payload = line:match("^data:%s*(.+)$")
        if payload then
            if payload == "[DONE]" then
                done = true
            else
                local obj = cjson.decode(payload)
                if obj and type(obj) == "table" then
                    if not has_content and event_has_content(obj) then
                        has_content = true
                    end
                    --Anthropic terminates with a message_stop event, not a
                    --[DONE] sentinel; both count as a completed stream.
                    if obj.type == "message_stop" then
                        done = true
                    end
                    local response = type(obj.response) == "table" and obj.response or obj
                    --message_start carries the input-side usage under
                    --obj.message.usage; message_delta carries the final
                    --output at the top level.
                    local candidate = response.usage
                    if type(obj.message) == "table" and type(obj.message.usage) == "table" then
                        candidate = obj.message.usage
                    end
                    if type(candidate) == "table" then
                        local normalized = normalize_usage(candidate)
                        if normalized then
                            usage = merge_usage(usage, normalized)
                        end
                        local ec = tonumber(candidate.estimated_cost)
                        if ec and ec > 0 then cost = ec end
                    end
                    local model_source = response.model
                    if type(obj.message) == "table" and type(obj.message.model) == "string" then
                        model_source = obj.message.model
                    end
                    if type(model_source) == "string" and model_source ~= "" and not model then
                        model = model_source
                    end
                    local chunk_cost = tonumber(obj.cost)
                    if chunk_cost and chunk_cost > 0 then
                        cost = chunk_cost
                    end
                end
            end
        end
    end
    return usage, model, done, cost, has_content
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
    if not usage then return 0, 0, 0, 0, 0, 0 end
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
    local cache_write = tonumber(usage.cache_write_tokens) or 0
    return pt, ct, tt, cached, reasoning, cache_write
end

return M
