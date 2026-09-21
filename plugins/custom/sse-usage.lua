local core = require("apisix.core")
local cjson = require("cjson.safe")
local http = require("resty.http")
local sse_lib = require("apisix.plugins.sse_usage_lib")
local cost_calc = require("apisix.plugins.cost_calc")
local model_registry = require("apisix.plugins.model_registry")
local resty_sha256 = require("resty.sha256")

local plugin_name = "sse-usage"

local plugin = {
    version = 0.1,
    priority = 2400,
    name = plugin_name,
}

function plugin.init()
    --provider-sync is the sole pricing/catalog writer; trigger it at
    --startup so the pricing cache is warm before the first request.
    local ok, provider_sync = pcall(require, "apisix.plugins.provider-sync")
    if not ok then
        core.log.warn("sse-usage: provider-sync module not available")
        return
    end
    if provider_sync and provider_sync.sync then
        --The catalog owns all sync defaults (providers dir, models.dev
        --URL, TTLs); callers pass an empty conf.
        local sok, err = pcall(provider_sync.sync, {})
        if not sok then
            core.log.warn("sse-usage: provider-sync initial sync failed: ", err or "unknown")
        end
    end
end

plugin.schema = {
    type = "object",
    properties = {
        clickhouse_addr = {
            type = "string",
            default = "http://clickhouse:8123",
        },
        clickhouse_user = {
            type = "string",
            default = "apisix_rw",
        },
        clickhouse_password_env = {
            type = "string",
            default = "CH_APISIX_PASSWORD",
        },
        sql_dir = {
            type = "string",
            default = "/etc/apisix/sql",
        },
        db = {
            type = "string",
            default = "llm_gateway",
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

-- SQL lives in conf/sql (AGENTS.md); load once and substitute the DB name.
local insert_query

local function usage_insert_sql(conf)
    if insert_query then return insert_query end
    local path = (conf.sql_dir or "/etc/apisix/sql") .. "/ingest/usage-log.insert.sql"
    local f = io.open(path, "r")
    if not f then
        return nil, "cannot open SQL template " .. path
    end
    local tpl = f:read("*a")
    f:close()
    local db = conf.db or "llm_gateway"
    insert_query = (tpl:gsub("%{%{%s*DB%s*%}%}", db):gsub("%s+$", ""))
    return insert_query
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

local function looks_like_sse(text)
    return type(text) == "string"
        and (text:find("event:", 1, true) ~= nil
            or text:find("data:", 1, true) ~= nil)
end

function plugin.body_filter(conf, ctx)
    local chunk = ngx.arg[1]
    local eof = ngx.arg[2]

    --TTFT (first byte): stamp once on the first non-empty response chunk.
    --Zero-cost guard; the stamp is the only per-chunk bookkeeping added here.
    if type(chunk) == "string" and chunk ~= "" and not ctx.sse_first_byte_ms then
        local start_s = ngx.req.start_time()
        if start_s then
            local ms = math.floor((ngx.now() - start_s) * 1000 + 0.5)
            if ms >= 0 then ctx.sse_first_byte_ms = ms end
        end
    end

    --OpenAI Responses can emit SSE frames while advertising a non-SSE response.
    --Keep telemetry enabled when response headers classify it as JSON.
    if not ctx.sse_usage_tracking then
        local uri = ctx.var and ctx.var.uri or ngx.var.uri or ""
        if ctx.route_id == "relay-openai" or uri:find("^/openai/") then
            ctx.sse_usage_tracking = true
            ctx.sse_is_stream = false
        end
    end

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
            --OpenAI-compatible Responses can return SSE for stream=false.
            --Detect the wire format from the body before choosing the parser.
            if not ctx.sse_is_stream and looks_like_sse(complete) then
                ctx.sse_is_stream = true
            end
            if ctx.sse_is_stream then
                local usage, model, done, cost, has_content = sse_lib.scan_sse_for_usage(complete)
                if done then ctx.sse_completed = true end
                if usage then ctx.sse_usage = usage end
                if model and model ~= "" then ctx.sse_model = model end
                if cost and cost > 0 then ctx.sse_cost = cost end
                if has_content and not ctx.sse_content_ms then
                    local start_s = ngx.req.start_time()
                    if start_s then
                        local ms = math.floor((ngx.now() - start_s) * 1000 + 0.5)
                        if ms >= 0 then ctx.sse_content_ms = ms end
                    end
                end
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
            if not ctx.sse_is_stream and looks_like_sse(ctx.sse_buffer) then
                ctx.sse_is_stream = true
            end
            if ctx.sse_is_stream then
                local usage, model, done, cost, has_content = sse_lib.scan_sse_for_usage(ctx.sse_buffer)
                if done then ctx.sse_completed = true end
                if usage then ctx.sse_usage = usage end
                if model and model ~= "" then ctx.sse_model = model end
                if cost and cost > 0 then ctx.sse_cost = cost end
                if has_content and not ctx.sse_content_ms then
                    local start_s = ngx.req.start_time()
                    if start_s then
                        local ms = math.floor((ngx.now() - start_s) * 1000 + 0.5)
                        if ms >= 0 then ctx.sse_content_ms = ms end
                    end
                end
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

    --Stream timing (REQ-USEFULNESS-TELEMETRY FR-1): duration at log phase,
    --TTFT stamps from body_filter. JSON responses deliver the whole body at
    --once, so both TTFT columns equal duration. Aborted streams keep timing:
    --aborted=1 with ttft_first_byte_ms=0 < duration_ms marks a cancel before
    --first byte.
    local duration_ms = 0
    local start_s = ngx.req.start_time()
    if start_s then
        local ms = math.floor((ngx.now() - start_s) * 1000 + 0.5)
        if ms > 0 then duration_ms = ms end
    end
    local ttft_first_byte = ctx.sse_first_byte_ms or 0
    local ttft_content = ctx.sse_content_ms or 0
    if is_stream == 0 then
        ttft_first_byte = duration_ms
        ttft_content = duration_ms
    end

    local pt, ct, tt, cached, reasoning, cache_write = sse_lib.extract_tokens(ctx.sse_usage)
    local model = ctx.sse_model or ""
    local reported_cost = tonumber(ctx.sse_cost) or 0
    local req_model = ctx.sse_req_model or model
    local route_id = ctx.route_id or ""

    --Use ngx.var.start_time (Nginx $start_time, seconds.millis string), same source Vector reads.
    --to_int() in VRL truncates to integer seconds, so match that.
    local start_time_sec = math.floor(tonumber(ngx.var.start_time)
        or ngx.req.start_time() or 0)
    local event_id = route_id .. "_" .. tostring(start_time_sec)

    --Provider identity is resolved exactly like the offline recalc
    --(cost_calc.resolve_provider): explicit alias first, then the request's
    --provider id, then the route map. No other provider is consulted.
    local provider_id = cost_calc.resolve_provider(ctx.provider_id or "", event_id)

    local final_cost, cost_source = cost_calc.resolve_cost(
        { pt = pt, ct = ct, cached = cached, cache_write = cache_write, reasoning = reasoning },
        req_model,
        provider_id
    )
    --resolve_cost already returns the record's provenance, so the pricing
    --snapshot column reads it directly instead of looking the price up twice.
    local pricing_source = cost_source
    if cost_source == cost_calc.SOURCE_UNKNOWN then
        pricing_source = ""
    end
    local pricing_snapshot = ""
    local cache = ngx.shared and ngx.shared["gateway-cache"]
    if cache then
        pricing_snapshot = tostring(cache:get("pricing:snapshot:active") or "")
    end

    --For SSE streams that aborted early (no usage chunk received), the
    --request body is the model source of record so abort rows remain
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

    --Canonicalize model via the single-source-of-truth registry
    --(conf/model-registry.yaml -> model_registry.lua). The verbatim
    --string is preserved in model_raw for audit. The same mapping is
    --codegenned into conf/vector.toml so request_log.model is
    --canonical too and the Grafana model variable UNION stays clean.
    local model_raw = model
    model = model_registry.canonical(model)

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

    --request_id: read the X-Request-Id request header (set by the APISIX
    --request-id plugin in the rewrite phase) so the value matches exactly
    --what Vector writes to request_log. Fall back to nginx's $request_id
    --if the request-id plugin is not enabled.
    local request_id = ngx.var.http_x_request_id or ngx.var.request_id or ""

    local entry = cjson.encode({
        event_id = event_id,
        request_id = request_id,
        model = model,
        model_raw = model_raw,
        prompt_tokens = pt,
        completion_tokens = ct,
        total_tokens = tt,
        cached_tokens = cached,
        cache_write_tokens = cache_write,
        reasoning_tokens = reasoning,
        key_id = hashed,
        api_key_id = consumer,
        aborted = aborted,
        is_stream = is_stream,
        ttft_first_byte_ms = ttft_first_byte,
        ttft_content_ms = ttft_content,
        duration_ms = duration_ms,
        cost = final_cost,
        cost_source = cost_source,
        reported_cost = reported_cost,
        provider_id = provider_id or "",
        pricing_source = pricing_source or "",
        pricing_snapshot = pricing_snapshot,
    })

    if not entry then
        core.log.error("sse-usage: failed to encode usage entry")
        return
    end

    local clickhouse_addr = conf.clickhouse_addr
    local body = entry .. "\n"

    --Basic auth for the usage_log insert (REQ-SECURITY-HARDENING FR-1.1).
    local ch_user = conf.clickhouse_user or "apisix_rw"
    local ch_pass = os.getenv(conf.clickhouse_password_env or "CH_APISIX_PASSWORD") or ""
    if ch_pass == "" then
        core.log.error("sse-usage: env ", conf.clickhouse_password_env or "CH_APISIX_PASSWORD",
                       " not set; usage_log insert will be rejected")
    end
    local ch_auth = "Basic " .. ngx.encode_base64(ch_user .. ":" .. ch_pass)

    local max_retries = 3
    local retry_delays = {0.1, 0.5, 2.0}

    local timer_handler
    timer_handler = function(premature, retry_count)
        if premature then return end
        retry_count = retry_count or 0

        local query_sql, qerr = usage_insert_sql(conf)
        if not query_sql then
            core.log.error("sse-usage: ", qerr)
            return
        end

        local httpc = http.new()
        httpc:set_timeout(5000)
        local res, err = httpc:request_uri(clickhouse_addr .. "/", {
            method = "POST",
            query = {query = query_sql},
            body = body,
            headers = {
                ["Content-Type"] = "application/json",
                ["Authorization"] = ch_auth,
            },
        })
        --A transport error OR a non-200 status is a failed insert; retry
        --both, otherwise the row is dropped without a record.
        local ok_status = res and res.status == 200
        if not ok_status and retry_count < max_retries then
            core.log.warn("sse-usage: clickhouse insert failed (attempt ",
                          retry_count + 1, "/", max_retries, "): ",
                          err or ("status " .. tostring(res and res.status)))
            local ok, timer_err = ngx.timer.at(retry_delays[retry_count + 1] or 1, timer_handler, retry_count + 1)
            if not ok then
                core.log.error("sse-usage: retry timer creation failed: ", timer_err)
            end
            return
        end
        if not ok_status then
            core.log.error("sse-usage: clickhouse insert failed after ",
                           max_retries, " attempts: ",
                           err or ("status " .. tostring(res and res.status)),
                           res and res.body and (": " .. res.body) or "")
        end
    end

    local ok, err = ngx.timer.at(0, timer_handler, 0)
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
