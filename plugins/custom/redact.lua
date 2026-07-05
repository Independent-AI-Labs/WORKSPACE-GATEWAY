local core = require("apisix.core")
local cjson = require("cjson.safe")
local redact_lib = require("redact_lib")

local plugin_name = "redact"

local plugin = {
    PRIORITY = 2500,
    name = plugin_name,
}

plugin.schema = {
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

function plugin.check_schema(conf)
    return core.schema.check(plugin.schema, conf)
end

function plugin.access(conf, ctx)
    local conf_path = conf.patterns_file
        or "/etc/apisix/redact-patterns.json"
    local loaded_patterns, dict_alt = redact_lib.load_patterns(conf_path)
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
            msg.content = redact_lib.redact_text(
                msg.content, loaded_patterns, dict_alt,
                counters, token_map, conf.redact_ips
            )
        elseif type(msg.content) == "table" then
            for _, part in ipairs(msg.content) do
                if part.text then
                    part.text = redact_lib.redact_text(
                        part.text, loaded_patterns, dict_alt,
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

function plugin.header_filter(conf, ctx)
    if not ctx.redact_active then return end
    ngx.header.content_length = nil
    core.response.set_header(ctx, "X-Redact-Active", "1")
end

function plugin.body_filter(conf, ctx)
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
        new_body = redact_lib.restore_with_key(full_body, ctx.redact_token_map)
    else
        local ok, parsed = pcall(cjson.decode, full_body)
        if ok and parsed.choices then
            for _, ch in ipairs(parsed.choices) do
                if ch.message and ch.message.content then
                    ch.message.content = redact_lib.restore_with_key(
                        ch.message.content, ctx.redact_token_map
                    )
                end
            end
            new_body = cjson.encode(parsed)
        else
            new_body = redact_lib.restore_with_key(full_body, ctx.redact_token_map)
        end
    end

    ngx.arg[1] = new_body
    ngx.arg[2] = true
    ctx.redact_buffer = nil
end

function plugin.log(conf, ctx)
    if not ctx.redact_active then return end
    ctx.redact_log = {
        active = true,
        token_count = ctx.redact_token_count or 0,
        stream = ctx.redact_stream or false,
    }
end

return plugin