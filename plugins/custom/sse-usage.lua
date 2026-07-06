local core = require("apisix.core")
local cjson = require("cjson.safe")
local http = require("resty.http")
local sse_lib = require("apisix.plugins.sse_usage_lib")

local plugin_name = "sse-usage"

local plugin = {
    version = 0.1,
    priority = 2400,
    name = plugin_name,
}

plugin.schema = {
    type = "object",
    properties = {
        clickhouse_addr = {
            type = "string",
            default = "http://clickhouse:8123",
        },
    },
}

function plugin.check_schema(conf)
    return core.schema.check(plugin.schema, conf)
end

local function is_sse()
    local ct = ngx.header.content_type
    if not ct then return false end
    return ct:find("text/event-stream", 1, true) ~= nil
end

local function is_json()
    local ct = ngx.header.content_type
    if not ct then return false end
    return ct:find("application/json", 1, true) ~= nil
end

function plugin.body_filter(conf, ctx)
    local chunk = ngx.arg[1]
    local eof = ngx.arg[2]

    if not ctx.sse_usage_tracking then
        return
    end

    if type(chunk) == "string" and chunk ~= "" then
        local complete, remainder = sse_lib.buffer_chunk(
            ctx.sse_buffer, chunk)
        ctx.sse_buffer = remainder

        if complete ~= "" then
            local usage, model
            if ctx.sse_is_stream then
                usage, model = sse_lib.scan_sse_for_usage(complete)
            else
                usage, model = sse_lib.parse_json_usage(complete)
            end
            if usage then
                ctx.sse_usage = usage
                if model then ctx.sse_model = model end
            end
        end
    end

    if eof then
        if ctx.sse_buffer and ctx.sse_buffer ~= "" then
            local usage, model
            if ctx.sse_is_stream then
                usage, model = sse_lib.scan_sse_for_usage(ctx.sse_buffer)
            else
                usage, model = sse_lib.parse_json_usage(ctx.sse_buffer)
            end
            if usage then
                ctx.sse_usage = usage
                if model then ctx.sse_model = model end
            end
            ctx.sse_buffer = nil
        end
    end
end

function plugin.header_filter(conf, ctx)
    if is_sse() then
        ctx.sse_usage_tracking = true
        ctx.sse_is_stream = true
    elseif is_json() then
        ctx.sse_usage_tracking = true
        ctx.sse_is_stream = false
    end
end

function plugin.log(conf, ctx)
    if not ctx.sse_usage then return end

    local pt, ct, tt = sse_lib.extract_tokens(ctx.sse_usage)
    local model = ctx.sse_model or ""

    local route_id = ctx.route_id or ""
    local start_time = ctx.start_time or 0
    local event_id = route_id .. "_" .. tostring(start_time)

    local entry = cjson.encode({
        event_id = event_id,
        model = model,
        prompt_tokens = pt,
        completion_tokens = ct,
        total_tokens = tt,
    })

    if not entry then
        core.log.error("sse-usage: failed to encode usage entry")
        return
    end

    local clickhouse_addr = conf.clickhouse_addr
    local body = entry .. "\n"

    local timer_handler
    timer_handler = function(premature)
        if premature then return end
        local httpc = http.new()
        local res, err = httpc:request_uri(clickhouse_addr .. "/", {
            method = "POST",
            query = {query = "INSERT INTO llm_gateway.usage_log FORMAT JSONEachRow"},
            body = body,
            headers = {["Content-Type"] = "application/json"},
            timeout = 5000,
        })
        if not res then
            core.log.error("sse-usage: clickhouse insert failed: ", err)
            return
        end
        if res.status ~= 200 then
            core.log.error("sse-usage: clickhouse returned status ", res.status,
                           ": ", res.body or "")
        end
    end

    local ok, err = ngx.timer.at(0, timer_handler)
    if not ok then
        core.log.error("sse-usage: failed to create timer: ", err)
    end
end

return plugin
