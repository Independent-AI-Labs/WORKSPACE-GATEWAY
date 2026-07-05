local cjson = require("cjson.safe")

local M = {}

function M.luhn_valid(card_number)
    card_number = card_number:gsub("[%s-]", "")
    local sum, parity = 0, 0
    for i = #card_number, 1, -1 do
        local digit = tonumber(card_number:sub(i, i))
        if not digit then return false end
        if parity % 2 == 1 then
            digit = digit * 2
            if digit > 9 then digit = digit - 9 end
        end
        sum = sum + digit
        parity = parity + 1
    end
    return sum % 10 == 0
end

function M.load_patterns(filepath)
    local file, err = io.open(filepath, "r")
    if not file then return nil, err end
    local content = file:read("*a")
    file:close()
    local data = cjson.decode(content)
    if not data then return nil, "json decode failed" end

    local dict_alt = nil
    if data.dictionary then
        local parts = {}
        for _, dict in ipairs(data.dictionary) do
            for _, entry in ipairs(dict.entries or {}) do
                local escaped = entry:gsub("([^%w%s])", "%%%1")
                parts[#parts + 1] = escaped
            end
        end
        if #parts > 0 then
            dict_alt = table.concat(parts, "|")
        end
    end
    return data, dict_alt
end

function M.redact_text(text, patterns, dict_alt, counters, token_map, redact_ips)
    if not text or text == "" then return text end

    for _, p in ipairs(patterns.regex or {}) do
        if p.kind ~= "ipv4" or redact_ips then
            local kind_key = string.upper(p.kind)
            local luhn = p.luhn_check
            local function replace_cb(m)
                local match_text = m[0]
                if luhn and not M.luhn_valid(match_text) then
                    return match_text
                end
                counters[kind_key] = (counters[kind_key] or 0) + 1
                local token = string.format("[%s_%d]", kind_key, counters[kind_key])
                token_map[token] = match_text
                return token
            end
            local result, _, gsub_err = ngx.re.gsub(text, p.pattern, replace_cb, "ijo")
            if result then
                text = result
            elseif gsub_err then
                io.stderr:write("[redact_lib] gsub error for kind ", p.kind, ": ", gsub_err, "\n")
            end
        end
    end

    if dict_alt then
        local function dict_replace_cb(m)
            local match_text = m[0]
            counters["DICTIONARY"] = (counters["DICTIONARY"] or 0) + 1
            local token = string.format("[DICTIONARY_%d]", counters["DICTIONARY"])
            token_map[token] = match_text
            return token
        end
        local dresult, _, derr = ngx.re.gsub(text, dict_alt, dict_replace_cb, "ijo")
        if dresult then
            text = dresult
        elseif derr then
            io.stderr:write("[redact_lib] gsub error for dictionary: ", derr, "\n")
        end
    end

    return text
end

function M.restore_with_key(text, key)
    if not key or not text then return text end
    local result = text
    for token, original in pairs(key) do
        local esc = token:gsub("([^%w])", "%%%1")
        result = result:gsub(esc, original)
    end
    return result
end

return M