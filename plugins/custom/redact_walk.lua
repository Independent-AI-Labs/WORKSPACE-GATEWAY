local redact_lib = require("apisix.plugins.redact_lib")

local M = {}

local function redact_text_value(value, patterns, dict_alt, counters, token_map, redact_ips)
    if type(value) ~= "string" then return value end
    return redact_lib.redact_text(value, patterns, dict_alt, counters, token_map, redact_ips)
end

local function redact_content_parts(parts, patterns, dict_alt, counters, token_map, redact_ips)
    if type(parts) == "string" then
        return redact_text_value(parts, patterns, dict_alt, counters, token_map, redact_ips)
    end
    if type(parts) ~= "table" then return parts end
    for _, part in ipairs(parts) do
        if type(part) == "table" and part.type == "input_text" and part.text then
            part.text = redact_text_value(part.text, patterns, dict_alt, counters, token_map, redact_ips)
        elseif type(part) == "table" and part.type == "text" and part.text then
            part.text = redact_text_value(part.text, patterns, dict_alt, counters, token_map, redact_ips)
        end
    end
    return parts
end

function M.redact_request(parsed, patterns, dict_alt, counters, token_map, redact_ips)
    if type(parsed) ~= "table" then return false end

    if type(parsed.messages) == "table" then
        for _, msg in ipairs(parsed.messages) do
            if type(msg) == "table" and msg.content ~= nil then
                msg.content = redact_content_parts(msg.content, patterns, dict_alt, counters, token_map, redact_ips)
            end
        end
        return true
    end

    if parsed.input ~= nil then
        parsed.instructions = redact_text_value(parsed.instructions, patterns, dict_alt, counters, token_map, redact_ips)
        if type(parsed.input) == "string" then
            parsed.input = redact_text_value(parsed.input, patterns, dict_alt, counters, token_map, redact_ips)
        elseif type(parsed.input) == "table" then
            for _, item in ipairs(parsed.input) do
                if type(item) == "table" then
                    if item.content ~= nil then
                        item.content = redact_content_parts(item.content, patterns, dict_alt, counters, token_map, redact_ips)
                    end
                    if item.type == "function_call" and item.arguments then
                        item.arguments = redact_text_value(item.arguments, patterns, dict_alt, counters, token_map, redact_ips)
                    elseif item.type == "function_call_output" and item.output then
                        item.output = redact_text_value(item.output, patterns, dict_alt, counters, token_map, redact_ips)
                    end
                end
            end
        end
        return true
    end

    return false
end

return M
