local core = require("apisix.core")
local cjson = require("cjson.safe")
local http = require("resty.http")
local sse_lib = require("apisix.plugins.sse_usage_lib")
local cost_calc = require("apisix.plugins.cost_calc")
local resty_sha256 = require("resty.sha256")

local plugin_name = "sse-usage"

local plugin = {
    version = 0.1,
    priority = 2400,
    name = plugin_name,
}

function plugin.init()
    local ok, err = cost_calc.warmup()
    if not ok then
        core.log.warn("sse-usage: cost_calc.warmup() failed: ", err or "unknown")
    end
end

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

function plugin.access(conf, ctx)
    local body, err = core.request.get_body()
    if body and type(body) == "table" and body.model then
        ctx.sse_req_model = tostring(body.model)
    end
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

    if eof then
        ctx.sse_upstream_eof = true
    end

    if type(chunk) == "string" and chunk ~= "" then
        local complete, remainder = sse_lib.buffer_chunk(
            ctx.sse_buffer, chunk)
        ctx.sse_buffer = remainder

        if complete ~= "" then
            if ctx.sse_is_stream then
                local usage, model, done, cost = sse_lib.scan_sse_for_usage(complete)
                if done then ctx.sse_completed = true end
                if usage then ctx.sse_usage = usage end
                if model and model ~= "" then ctx.sse_model = model end
                if cost and cost > 0 then ctx.sse_cost = cost end
            else
                local usage, model, cost = sse_lib.parse_json_usage(complete)
                if usage then
                    ctx.sse_usage = usage
                    if model and model ~= "" then ctx.sse_model = model end
                    if cost and cost > 0 then ctx.sse_cost = cost end
                end
            end
        end
    end

    if eof then
        if ctx.sse_buffer and ctx.sse_buffer ~= "" then
            if ctx.sse_is_stream then
                local usage, model, done, cost = sse_lib.scan_sse_for_usage(ctx.sse_buffer)
                if done then ctx.sse_completed = true end
                if usage then ctx.sse_usage = usage end
                if model and model ~= "" then ctx.sse_model = model end
                if cost and cost > 0 then ctx.sse_cost = cost end
            else
                local usage, model, cost = sse_lib.parse_json_usage(ctx.sse_buffer)
                if usage then
                    ctx.sse_usage = usage
                    if model and model ~= "" then ctx.sse_model = model end
                    if cost and cost > 0 then ctx.sse_cost = cost end
                end
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
    if not ctx.sse_usage_tracking then return end

    --For non-SSE (JSON) responses, only log if usage found (existing behavior)
    if not ctx.sse_is_stream and not ctx.sse_usage then return end

    --Determine abort direction:
    --0 = completed ([DONE] seen)
    --1 = client aborted (no upstream eof → client disconnected first)
    --2 = provider aborted (upstream closed without [DONE])
    local aborted = 0
    if ctx.sse_is_stream and not ctx.sse_completed then
        if ctx.sse_upstream_eof then
            aborted = 2
        else
            aborted = 1
        end
    end

    local is_stream = ctx.sse_is_stream and 1 or 0

    local pt, ct, tt, cached, reasoning = sse_lib.extract_tokens(ctx.sse_usage)
    local model = ctx.sse_model or ""
    local sse_cost = tonumber(ctx.sse_cost) or 0
    local req_model = ctx.sse_req_model or model

    local final_cost, cost_source = cost_calc.resolve_cost(
        sse_cost,
        { pt = pt, ct = ct, cached = cached, reasoning = reasoning },
        req_model
    )

    --For SSE streams that aborted early (no usage chunk received), fall
    --back to the request body to get the model so abort rows remain
    --filterable by the dashboard model variable.
    if model == "" then
        local req_body = ngx.req.get_body_data()
        if type(req_body) == "string" and req_body ~= "" then
            local req_parsed = cjson.decode(req_body)
            if req_parsed and type(req_parsed) == "table" and req_parsed.model then
                model = tostring(req_parsed.model)
            end
        end
    end

    local route_id = ctx.route_id or ""
    local start_time = ctx.start_time or 0
    local event_id = route_id .. "_" .. tostring(start_time)

    --Resolve + hash client key (mirrors conf/vector.toml VRL hashing
    --so usage_log.key_id == request_log.key_id for the same request).
    local consumer = ctx.consumer and ctx.consumer.username or ""
    local resolved_key_id = ngx.var.http_x_gateway_key_id or ""
    local auth_hdr = ngx.var.http_authorization or ""
    local tok = ""
    if auth_hdr ~= "" then
        local m = auth_hdr:match("^%s*[Bb]earer%s+(.+)$")
        if m then tok = m end
    end

    local final_key = resolved_key_id
    if (resolved_key_id == "" or resolved_key_id == "passthrough") and tok ~= "" then
        final_key = tok
    end

    local hashed = ""
    if final_key ~= "" then
        local d = resty_sha256:new()
        d:update(final_key)
        local bin = d:final()
        local hex = {}
        for i = 1, #bin do
            hex[i] = string.format("%02x", string.byte(bin, i))
        end
        hashed = table.concat(hex):sub(1, 16)
    end

    local entry = cjson.encode({
        event_id = event_id,
        model = model,
        prompt_tokens = pt,
        completion_tokens = ct,
        total_tokens = tt,
        cached_tokens = cached,
        reasoning_tokens = reasoning,
        key_id = hashed,
        api_key_id = consumer,
        aborted = aborted,
        is_stream = is_stream,
        cost = final_cost,
        cost_source = cost_source,
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

    --- Per-key budget counter increment (Tier 3)
    if ctx.quota_bucket_key then
        local qd = ngx.shared.quota_counters
        if qd then
            local increment
            if ctx.quota_type == "cost" then
                increment = math.ceil((tonumber(final_cost) or 0) * 100)
            else
                increment = tonumber(tt) or 0
            end
            if increment > 0 then
                local new_val = qd:incr(ctx.quota_bucket_key, increment)
                qd:set(ctx.quota_bucket_key, new_val or increment, ctx.quota_window * 2 or 172800)
            end
        else
            core.log.error("sse-usage: quota_counters shared dict not configured")
        end
    end
end

return plugin
