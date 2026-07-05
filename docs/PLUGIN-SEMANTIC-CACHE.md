# Plugin Spec: Semantic Cache - APISIX Custom Lua Plugin (v2)

**Document ID:** AMI-PROP-LLMGW-PLUGIN-SEMANTIC-CACHE-v2.0
**Status:** Draft (v2, deferred implementation)
**Date:** 2026-07-05
**Parent:** `PROPOSAL-LLM-GATEWAY-v3.md`; inherits `PLUGIN-FOUNDATION.md`
**Replaces:** Kong Enterprise `ai-semantic-cache` (replaced by this custom Lua plugin)

This document specifies the **pure Lua APISIX plugin** that implements a semantic
cache for LLM chat completions using Redis Vector Similarity Search (VSS). The
plugin queries Redis VSS directly via `lua-resty-redis` cosocket (no cache-shim
sidecar). Embedding computation is delegated to a **Rust embedding sidecar**
(torch/llama.cpp local model, not OpenAI API) via `lua-resty-http` cosocket.

**v2 spec**, not implemented in v1. v1 ships without semantic cache.

---

## 1. Architecture

```
APISIX custom Lua plugin (semantic-cache)           Embedding Sidecar (Rust)
+-----------------------------------------+        +----------------------+
| access phase:                            |        | axum/hyper server    |
|   extract messages from request body     |  POST  | POST /v1/embeddings  |
|   call embedding sidecar (cosocket)      | -----> | torch or llama.cpp   |
|   query Redis VSS (FT.SEARCH, cosocket)  |        | local embedding model|
|   if HIT: synth response, return 200     | <----- | returns float[] vector|
|   if MISS: stash embed+prompt in ctx     |        +----------------------+
|                                          |
| body_filter:                             |
|   if MISS: capture response chunks       |
|   at EOF: build canonical JSON           |
|                                          |
| log phase (ngx.timer.at):               |
|   if MISS: store canonical JSON in Redis |
|   HSET + EXPIRE (cosocket)              |
+-----------------------------------------+
                                          Redis 8 (VSS)
                                          +----------------------+
                                          | FT.SEARCH idx:semcache|
                                          | KNN + TAG pre-filter  |
                                          | (tenant, tier)        |
                                          +----------------------+
```

**No cache-shim sidecar.** Redis VSS queries (`FT.SEARCH` with KNN + TAG
pre-filter) are plain Redis commands executed via `lua-resty-redis` cosocket.
The only sidecar is the Rust embedding service.

---

## 2. Plugin Manifest

```lua
local core = require("apisix.core")

local _M = {
    version = 0.1,
    priority = 2550,          -- after auth (2599), before redact (2500)
    name = "semantic-cache",
}
```

---

## 3. Schema

```lua
_M.schema = {
    type = "object",
    properties = {
        embedding_url   = { type = "string", required = true },
        embedding_model = { type = "string", default = "bge-large-en-v1.5" },
        embedding_dim   = { type = "integer", default = 1024 },
        redis_host      = { type = "string", default = "127.0.0.1" },
        redis_port      = { type = "integer", default = 6379 },
        redis_db        = { type = "integer", default = 0 },
        distance_threshold = { type = "number", default = 0.10,
                               description = "cosine distance [0-2]; 0.10 ~ 0.95 similarity" },
        cache_ttl_seconds  = { type = "integer", default = 300 },
        timeout_ms         = { type = "integer", default = 2000 },
        message_countback  = { type = "integer", default = 1 },
        ignore_system_prompts = { type = "boolean", default = true },
        stop_on_failure    = { type = "boolean", default = false },
    },
}

function _M.check_schema(conf)
    return core.schema.check(_M.schema, conf)
end
```

---

## 4. `access` Phase

```lua
local cjson = require("cjson.safe")
local http = require("resty.http")
local redis = require("resty.redis")
local ffi = require("ffi")

-- Pack float32 vector into binary blob for Redis FT.SEARCH PARAMS
local function pack_vector(vec)
    local len = #vec
    local buf = ffi.new("float[?]", len)
    for i = 1, len do
        buf[i - 1] = vec[i]
    end
    return ffi.string(buf, len * 4)  -- 4 bytes per float32
end

function _M.access(conf, ctx)
    -- 1. Read isolation headers (injected by auth plugin).
    local tenant = core.request.header(ctx, "x-tenant-id")
    local tier = core.request.header(ctx, "x-routing-tier")
    if not tenant or tenant == "" or not tier or tier == "" then
        return 403, { error = "missing_isolation_metadata" }
    end

    -- 2. Read and parse request body.
    core.request.read_body(ctx)
    local body = core.request.get_body(ctx)
    if not body or body == "" then return end

    local ok, parsed = pcall(cjson.decode, body)
    if not ok or not parsed.messages then return end

    -- 3. Extract prompt text (trailing N messages, skip system).
    local prompt_text = extract_prompt(parsed.messages, conf)
    if not prompt_text or prompt_text == "" then return end

    -- 4. Call embedding sidecar (cosocket, non-blocking).
    local httpc = http.new()
    httpc:set_timeout(conf.timeout_ms)
    local res, err = httpc:request_uri(conf.embedding_url, {
        method = "POST",
        body = cjson.encode({
            model = conf.embedding_model,
            input = prompt_text,
        }),
        headers = { ["Content-Type"] = "application/json" },
    })
    httpc:set_keepalive()

    if not res or res.status ~= 200 then
        core.log.error("semantic-cache: embedding failed: ", err or res.status)
        ctx.cache_status = "MISS-EMBED-FAIL"
        return  -- MISS; request proceeds to upstream
    end

    local embed = cjson.decode(res.body)
    if not embed or not embed.data or not embed.data[1] then
        ctx.cache_status = "MISS-EMBED-MALFORMED"
        return
    end

    local vector = embed.data[1].embedding
    if #vector ~= conf.embedding_dim then
        ctx.cache_status = "MISS-EMBED-DIM-MISMATCH"
        return  -- never store wrong-dim vector (silent-garbage risk)
    end

    -- 5. Query Redis VSS (cosocket, non-blocking).
    local red = redis:new()
    red:set_timeout(conf.timeout_ms)
    local ok, err = red:connect(conf.redis_host, conf.redis_port)
    if not ok then
        core.log.error("semantic-cache: redis connect failed: ", err)
        ctx.cache_status = "MISS-QUERY-FAIL"
        return
    end

    local vec_blob = pack_vector(vector)
    -- FT.SEARCH with hybrid TAG + KNN pre-filter
    local query = string.format(
        'FT.SEARCH idx:semcache "(@tenant:{%s} @tier:{%s})=>[KNN 1 @embedding $qvec AS distance]" '
        .. 'PARAMS 2 qvec %s LIMIT 0 1 RETURN 5 distance response stream_mode format DIALECT 2',
        tenant, tier, vec_blob
    )
    local res2, err = red:do_raw(query)
    red:set_keepalive()

    if not res2 then
        core.log.error("semantic-cache: redis query failed: ", err)
        ctx.cache_status = "MISS-QUERY-FAIL"
        return
    end

    -- 6. Parse FT.SEARCH response (RESP3 array format)
    local hit = parse_ft_search_response(res2)
    if not hit or not hit.response then
        -- MISS: stash for log-phase store
        ctx.cache_miss = true
        ctx.cache_vector = vector
        ctx.cache_prompt = prompt_text
        ctx.cache_tenant = tenant
        ctx.cache_tier = tier
        ctx.cache_stream = parsed.stream and true or false
        ctx.cache_request_body = body
        return
    end

    -- 7. HIT: synthesize response and return.
    local client_stream = parsed.stream and true or false
    local content_type, response_body = frame_response(
        hit.stream_mode, client_stream, hit.response, body
    )

    core.response.set_header(ctx, "X-Cache", "HIT")
    core.response.set_header(ctx, "Content-Type", content_type)
    return 200, response_body  -- short-circuit; no upstream call
end
```

---

## 5. `body_filter` Phase (Response Capture on MISS)

```lua
function _M.body_filter(conf, ctx)
    if not ctx.cache_miss then return end

    local chunk = ngx.arg[1]
    if chunk then
        ctx.cache_response_buffer = (ctx.cache_response_buffer or "") .. chunk
    end
    -- Don't modify ngx.arg[1], let chunks pass through to the client normally.
end
```

At EOF, the full response body is in `ctx.cache_response_buffer`. If the response
was streaming (SSE), parse it to canonical JSON for storage:

```lua
-- Called in body_filter at EOF or in log phase
local function to_canonical_json(response_body, was_stream)
    if not was_stream then
        -- Already JSON; return as-is
        return response_body
    end
    -- Parse SSE frames: "data: {…}\n\ndata: {…}\n…\ndata: [DONE]\n\n"
    -- Extract content from delta chunks, build canonical JSON:
    -- { "choices": [{ "message": { "role": "assistant", "content": "…" } }] }
    local content_parts = {}
    for data in response_body:gmatch("data: (.-)\n\n") do
        if data == "[DONE]" then break end
        local ok, chunk = pcall(cjson.decode, data)
        if ok and chunk.choices and chunk.choices[1].delta then
            local delta = chunk.choices[1].delta.content
            if delta then content_parts[#content_parts + 1] = delta end
        end
    end
    return cjson.encode({
        choices = {{
            message = { role = "assistant", content = table.concat(content_parts) }
        }}
    })
end
```

---

## 6. `log` Phase (Store on MISS)

```lua
function _M.log(conf, ctx)
    if not ctx.cache_miss then return end
    if not ctx.cache_response_buffer then return end

    -- Build canonical JSON from the captured response
    local canonical = to_canonical_json(ctx.cache_response_buffer, ctx.cache_stream)
    if not canonical or canonical == "" then return end

    -- Store in Redis (off-thread via ngx.timer.at for cosocket access)
    local store_conf = conf
    local store_ctx = {
        vector = ctx.cache_vector,
        prompt = ctx.cache_prompt,
        tenant = ctx.cache_tenant,
        tier = ctx.cache_tier,
        stream = ctx.cache_stream,
        canonical = canonical,
    }

    ngx.timer.at(0, function(premature)
        if premature then return end
        local red = redis:new()
        red:set_timeout(store_conf.timeout_ms)
        local ok, err = red:connect(store_conf.redis_host, store_conf.redis_port)
        if not ok then
            core.log.error("semantic-cache: store redis connect failed: ", err)
            return
        end

        local key = "semcache:" .. store_ctx.tenant .. ":" .. store_ctx.tier
                   .. ":" .. core.utils.uuid()
        local vec_blob = pack_vector(store_ctx.vector)

        -- HSET + EXPIRE
        red:hset(key, "embedding", vec_blob)
        red:hset(key, "prompt", store_ctx.prompt)
        red:hset(key, "response", store_ctx.canonical)
        red:hset(key, "stream_mode", store_ctx.stream and "sse" or "json")
        red:hset(key, "format", "openai")
        red:hset(key, "tenant", store_ctx.tenant)
        red:hset(key, "tier", store_ctx.tier)
        red:expire(key, store_conf.cache_ttl_seconds)
        red:set_keepalive()
    end)
end
```

---

## 7. Redis VSS Schema

### 7.1 Index creation (one-time, at startup)

```
FT.CREATE idx:semcache ON HASH PREFIX 1 semcache:
  SCHEMA
    tenant       TAG
    tier         TAG
    prompt       TEXT
    response     TEXT
    embedding    VECTOR HNSW 6
      TYPE FLOAT32
      DIM 1024
      DISTANCE_METRIC COSINE
      M 16
      EF_CONSTRUCTION 200
      EF_RUNTIME 10
```

### 7.2 Hybrid TAG + KNN query

```
FT.SEARCH idx:semcache
  "(@tenant:{tenant-123} @tier:{standard})=>[KNN 1 @embedding $qvec AS distance]"
  PARAMS 2 qvec <1024-float32-binary-blob>
  LIMIT 0 1
  RETURN 5 distance response stream_mode format
  DIALECT 2
```

Redis 8's `ADHOC_BF` filter mode gives exact KNN on the small per-tenant subset.
The TAG filter is applied BEFORE the KNN search, a tenant-456 request can NEVER
see tenant-123 entries.

### 7.3 Distance semantics

`COSINE` distance is `[0, 2]` (0 = identical, 2 = opposite). The plugin interprets
`distance_threshold = 0.10` as "hit if returned distance <= 0.10" = cosine
similarity >= 0.90.

---

## 8. Streaming Replay

### 8.1 Canonical JSON storage (v2 default)

Store the **non-streaming canonical JSON** of the upstream response. On HIT:

| Stored | Client wants | Action |
|--------|-------------|--------|
| JSON | `stream: false` | Send cached JSON as-is |
| JSON | `stream: true` | Synthesize SSE frames from JSON |

```lua
local function synth_sse_from_json(json_body, chat_id)
    local parsed = cjson.decode(json_body)
    local content = parsed.choices[1].message.content or ""
    local frames = {}
    -- Initial role frame
    frames[#frames+1] = string.format(
        'data: {"id":"%s","object":"chat.completion.chunk","choices":[{"delta":{"role":"assistant"},"index":0}]}\n\n',
        chat_id
    )
    -- Content frames (split by word for natural streaming feel)
    for word in content:gmatch("%S+%s*") do
        frames[#frames+1] = string.format(
            'data: {"id":"%s","object":"chat.completion.chunk","choices":[{"delta":{"content":"%s"},"index":0}]}\n\n',
            chat_id, word
        )
    end
    -- Final frame
    frames[#frames+1] = 'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n'
    return table.concat(frames)
end

local function frame_response(stored_mode, client_stream, body, request_body)
    if stored_mode == "json" and not client_stream then
        return "application/json", body
    elseif stored_mode == "json" and client_stream then
        return "text/event-stream", synth_sse_from_json(body, core.utils.uuid())
    elseif stored_mode == "sse" and not client_stream then
        return "application/json", parse_sse_to_json(body)
    else
        return "text/event-stream", body
    end
end
```

### 8.2 SSE-to-JSON parsing (for stored SSE replay to non-streaming client)

```lua
local function parse_sse_to_json(sse_body)
    -- Extract content from SSE frames, build canonical JSON
    -- (Same logic as to_canonical_json §5)
    return to_canonical_json(sse_body, true)
end
```

---

## 9. Embedding Sidecar Contract (Rust, v2)

The Rust embedding sidecar exposes an **OpenAI-compatible** API:

### 9.1 `POST /v1/embeddings`

Request:
```json
{
  "model": "bge-large-en-v1.5",
  "input": "How do I file a PTO request?"
}
```

Response (200):
```json
{
  "data": [{ "embedding": [0.0123, -0.0456, ...], "index": 0 }],
  "model": "bge-large-en-v1.5",
  "usage": { "prompt_tokens": 8, "total_tokens": 8 }
}
```

### 9.2 `GET /healthz`

```json
{"status":"ok","model":"bge-large-en-v1.5","dim":1024,"uptime_secs":12345}
```

### 9.3 Implementation notes

- Rust binary with `torch` (libtorch) or `llama.cpp` bindings for local model inference.
- Runs on `tokio::task::spawn_blocking` threads (CPU-bound inference).
- Model loaded once at startup, shared across requests via `Arc`.
- Listens on `127.0.0.1:8090` (localhost, same host as APISIX).
- See `PLUGIN-REDACT-ENGINE.md` §v2 for similar Rust binary pattern.

---

## 10. Failure Modes (graceful MISS, NEVER fail closed)

A cache that fails closed (denying requests when Redis is down) is a
denial-of-service amplifier. Errors are surfaced via response header + log, but
**the request ALWAYS proceeds to upstream on MISS**:

| Failure | Detection | Action |
|---------|-----------|--------|
| Tenant/tier header missing | header check | **403** (security failure, fail closed) |
| Embedding sidecar 5xx/unreachable | httpc returns nil or 5xx | MISS; `X-Cache: MISS-EMBED-FAIL` |
| Embedding timeout | httpc timeout | MISS; `X-Cache: MISS-EMBED-FAIL` |
| Embedding wrong dim | `#vector != embedding_dim` | MISS; **never store wrong vector** |
| Redis connect/query 5xx | red returns nil | MISS; `X-Cache: MISS-QUERY-FAIL` |
| Redis FT.SEARCH timeout | red timeout | MISS |
| Threshold miss (distance > threshold) | `hit.distance > threshold` | normal MISS → forward + store |
| Store failure (log phase) | red returns nil | log; don't retry; response already delivered |
| `stop_on_failure: true` | any of above | 503 (NOT default; deliberate per-route opt-in) |

---

## 11. Test Plan

- Unit: `pack_vector` produces correct float32 binary blob (verify with `ffi.sizeof`).
- Unit: `synth_sse_from_json` produces valid OpenAI `chat.completion.chunk` frames
  ending in `data: [DONE]\n\n`.
- Unit: `to_canonical_json` extracts content from multi-frame SSE.
- Unit: dim-mismatch detection → MISS, never stored.
- Unit: missing-tenant → 403 (fail closed); missing-tier → 403.
- Integration: inject two prompts at cosine sim > 0.90 → second returns cached
  body with `X-Cache: HIT`.
- Integration: two tenants with identical prompts → tenant-A HIT does not bleed
  to tenant-B (B always MISS for fresh prompt).
- Integration: kill Redis → all requests MISS with `X-Cache: MISS-QUERY-FAIL`,
  never 5xx to client.
- Integration: streaming replay, client `stream:true`, cached entry stored as
  JSON → receives valid SSE.
- Integration: `stop_on_failure: true` → kill Redis → 503 to client.

---

## 12. Open Questions

| Q | Resolution |
|---|------------|
| Embedding model choice | Default `bge-large-en-v1.5` (1024 dim, Apache 2.0); configurable |
| `lua-resty-redis` `do_raw` for FT.SEARCH with binary PARAMS | Verify binary blob handling in `do_raw`; may need `ffi.string` + length prefix |
| Per-tenant Redis index vs shared + TAG filter | Default shared + TAG; per-tenant index opt-in via `index_name` in query |
| Vector Sets (`VADD`/`VSIM`) vs RediSearch FT.* | Default FT.* (Redis 8); Vector Sets alternative tracked |
| Store post-re-hydration or placeholder-laden response? | Store canonical JSON (post-re-hydration); redact plugin re-runs on cached HIT |

---

## 13. References

- Redis VSS FT.CREATE / FT.SEARCH + KNN: https://redis.io/docs/latest/develop/ai/search-and-query/vectors/
- Hybrid TAG + KNN pre-filter: https://redis.io/docs/latest/develop/ai/search-and-query/query/combined/
- Redis 8 expiry behavior: https://redis.io/docs/latest/develop/ai/search-and-query/advanced-concepts/expiration/
- `lua-resty-redis`: https://github.com/openresty/lua-resty-redis
- `lua-resty-http`: https://github.com/ledgetech/lua-resty-http
- APISIX plugin development: https://apisix.apache.org/docs/apisix/plugin-develop/
- OpenAI embeddings API format: https://platform.openai.com/docs/api-reference/embeddings
- BGE embedding models: https://huggingface.co/BAAI/bge-large-en-v1.5
- `lua-resty-redis` `do_raw` / pipeline: https://github.com/openresty/lua-resty-redis#do_raw

---

**End of document.**
