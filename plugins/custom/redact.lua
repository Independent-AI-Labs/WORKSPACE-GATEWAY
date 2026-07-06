local core = require("apisix.core")
local cjson = require("cjson.safe")
local redact_lib = require("apisix.plugins.redact_lib")

local plugin_name = "redact"

local plugin = {
    version = 0.1,
    priority = 2500,
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
    local shared = ngx.shared.redact_state
    local loaded_patterns, dict_alt

    local cached_json = shared:get("patterns")
    local cache_time = shared:get("patterns_time")
    local now_time = ngx.time()

    if cached_json and cache_time and (now_time - cache_time < 60) then
        loaded_patterns = cjson.decode(cached_json)
        if not loaded_patterns then
            loaded_patterns = nil
        end
        dict_alt = shared:get("dict_alt")
        if dict_alt == "" then dict_alt = nil end
    end

    if not loaded_patterns then
        loaded_patterns, dict_alt = redact_lib.load_patterns(conf_path)
        if loaded_patterns then
            local encoded = cjson.encode(loaded_patterns)
            if encoded then
                shared:set("patterns", encoded, 60)
                shared:set("patterns_time", now_time, 60)
            end
            if dict_alt then
                shared:set("dict_alt", dict_alt, 60)
            else
                shared:set("dict_alt", "", 60)
            end
        end
    end
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
    if not ok or not parsed then
        core.response.set_header("X-Redact-Error", "non-chat-body")
        return
    end
    if not parsed.messages then
        core.response.set_header("X-Redact-Error", "non-chat-body")
        return
    end

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

    local encode_ok, new_body = pcall(cjson.encode, parsed)
    if not encode_ok or not new_body then
        if conf.on_error == "closed" then
            return 503, { error = "redact: body re-encode failed" }
        end
        core.log.error("redact: body re-encode failed; proceeding with original body")
        return
    end
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
    core.response.set_header("X-Redact-Active", "1")
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