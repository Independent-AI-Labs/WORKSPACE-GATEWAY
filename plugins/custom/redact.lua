local core = require("apisix.core")
local cjson = require("cjson.safe")

local plugin_name = "redact"

local _M = {
    version = 0.1,
    priority = 2500,
    name = plugin_name,
}

_M.schema = {
    type = "object",
    properties = {
        patterns_file = {
            type = "string",
            default = "/etc/apisix/redact-patterns.json",
        },
        stream_mode = {
            type = "string",
            enum = { "reject", "buffer", "passthrough" },
            default = "buffer",
        },
        on_error = {
            type = "string",
            enum = { "closed", "open" },
            default = "closed",
        },
        redact_ips = {
            type = "boolean",
            default = false,
        },
    },
}

function _M.check_schema(conf)
    return core.schema.check(_M.schema, conf)
end

-- Module-level cache: loaded once per worker at init().
-- For hot-reload, restart the APISIX container.
local loaded_patterns = nil
local dict_alternation = nil

local function luhn_valid(card_number)
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

local function load_patterns(filepath)
    local file, err = io.open(filepath, "r")
    if not file then return nil, err end
    local content = file:read("*a")
    file:close()
    local data = cjson.decode(content)
    if not data then return nil, "json decode failed" end

    if data.dictionary then
        local parts = {}
        for _, dict in ipairs(data.dictionary) do
            for _, entry in ipairs(dict.entries or {}) do
                local escaped = entry:gsub("([^%w%s])", "%%%1")
                parts[#parts + 1] = escaped
            end
        end
        if #parts > 0 then
            dict_alternation = table.concat(parts, "|")
        end
    end
    return data
end

function _M.init()
    local conf_path = os.getenv("REDACT_PATTERNS_FILE")
        or "/etc/apisix/redact-patterns.json"
    local data, err = load_patterns(conf_path)
    if data then
        loaded_patterns = data
        core.log.info("redact: patterns loaded from ", conf_path)
    elseif err then
        core.log.error("redact: failed to load patterns: ", err)
    end
end

local function redact_text(text, patterns, counters, token_map, redact_ips)
    if not text or text == "" then return text end

    for _, p in ipairs(patterns.regex or {}) do
        if p.kind ~= "ipv4" or redact_ips then
            local kind_key = string.upper(p.kind)
            local luhn = p.luhn_check
            local function replace_cb(m)
                local match_text = m[0]
                if luhn and not luhn_valid(match_text) then
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
                core.log.error("redact: gsub error for kind ", p.kind, ": ", gsub_err)
            end
        end
    end

    if dict_alternation then
        local function dict_replace_cb(m)
            local match_text = m[0]
            counters["DICTIONARY"] = (counters["DICTIONARY"] or 0) + 1
            local token = string.format("[DICTIONARY_%d]", counters["DICTIONARY"])
            token_map[token] = match_text
            return token
        end
        text = ngx.re.gsub(text, dict_alternation, dict_replace_cb, "ijo")
    end

    return text
end

function _M.access(conf, ctx)
    if not loaded_patterns then
        if conf.on_error == "closed" then
            return 503, { error = "redact: patterns file not loaded" }
        end
        core.log.error("redact: patterns not loaded; proceeding unredacted")
        return
    end

    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body or body == "" then return end

    local ok, parsed = pcall(cjson.decode, body)
    if not ok or not parsed then return end
    if not parsed.messages then return end

    if parsed.stream and conf.stream_mode == "reject" then
        return 400, { error = "redact: streaming rejected" }
    end

    local counters = {}
    local token_map = {}

    for _, msg in ipairs(parsed.messages) do
        if type(msg.content) == "string" then
            msg.content = redact_text(
                msg.content, loaded_patterns,
                counters, token_map, conf.redact_ips
            )
        elseif type(msg.content) == "table" then
            for _, part in ipairs(msg.content) do
                if part.text then
                    part.text = redact_text(
                        part.text, loaded_patterns,
                        counters, token_map, conf.redact_ips
                    )
                end
            end
        end
    end

    local new_body = cjson.encode(parsed)
    ngx.req.set_body_data(new_body, #new_body)

    local count = 0
    for _ in pairs(token_map) do count = count + 1 end
    ctx.redact_token_map = token_map
    ctx.redact_active = count > 0
    ctx.redact_token_count = count
    ctx.redact_stream = parsed.stream and true or false
end

function _M.header_filter(conf, ctx)
    if not ctx.redact_active then return end
    ngx.header.content_length = nil
    core.response.set_header(ctx, "X-Redact-Active", "1")
end

local function restore_with_key(text, key)
    if not key or not text then return text end
    local result = text
    for token, original in pairs(key) do
        local esc = token:gsub("([^%w])", "%%%1")
        result = result:gsub(esc, original)
    end
    return result
end

function _M.body_filter(conf, ctx)
    if not ctx.redact_active then return end

    local chunk, eof = ngx.arg[1], ngx.arg[2]

    if conf.stream_mode == "passthrough" and ctx.redact_stream then
        return
    end

    ctx.redact_buffer = (ctx.redact_buffer or "") .. (chunk or "")
    if not eof then
        ngx.arg[1] = nil
        return
    end

    local full_body = ctx.redact_buffer
    local new_body

    if ctx.redact_stream then
        new_body = restore_with_key(full_body, ctx.redact_token_map)
    else
        local ok, parsed = pcall(cjson.decode, full_body)
        if ok and parsed.choices then
            for _, ch in ipairs(parsed.choices) do
                if ch.message and ch.message.content then
                    ch.message.content = restore_with_key(
                        ch.message.content, ctx.redact_token_map
                    )
                end
            end
            new_body = cjson.encode(parsed)
        else
            new_body = restore_with_key(full_body, ctx.redact_token_map)
        end
    end

    ngx.arg[1] = new_body
    ngx.arg[2] = true
    ctx.redact_buffer = nil
end

function _M.log(conf, ctx)
    if not ctx.redact_active then return end
    ctx.redact_log = {
        active = true,
        token_count = ctx.redact_token_count or 0,
        stream = ctx.redact_stream or false,
    }
end

return _M
