# Plugin Spec: PII Redaction - Lua Proxy Shell

**Document ID:** AMI-PROP-LLMGW-PLUGIN-REDACT-LUA-v1.0
**Status:** Draft
**Date:** 2026-07-04
**Parent:** `PROPOSAL-LLM-GATEWAY-v2.md`; inherits `PLUGIN-FOUNDATION.md`
**Companion:** `PLUGIN-REDACT-ENGINE.md` (the actual Rust redaction sidecar)

This document specifies the **thin in-process Lua Kong plugin** whose sole job is to:
buffer the OpenAI chat request body, forward it to the Rust redaction engine sidecar
(via HTTP cosocket in the `access` phase : the ONLY phase where cosockets are permitted),
stash the returned PII map in `kong.ctx.plugin`, then buffer the upstream response to EOF
and re-hydrate placeholders locally (no cosocket allowed in `body_filter`).

The actual redaction work (regex, Aho-Corasick, NER) lives in the **separate Rust
sidecar binary** specified in `PLUGIN-REDACT-ENGINE.md`. This Lua plugin is a *proxy
shell* : it owns the nginx request/response lifecycle glue, the sidecar owns the
computation. Mirrors the proven `kong-plugin-argus-redact` architecture but with the
sidecar in pure Rust instead of Python+PyO3.

---

## 1. Architecture

```
                      Lua plugin (in-process, Kong worker)
                     +--------------------------------------------------+
                     | access phase : buffer req body -> POST /redact   |
   request  ----->  |   (cosocket to redact-engine:8081)               |  -----> upstream LLM
                     |   stash PII map in kong.ctx.plugin               |
                     | header_filter: clear Content-Length (if active)  |
                     | body_filter  : buffer to EOF -> local gsub restore|
   response <-----  |                  from kong.ctx.plugin map          |  <----- upstream LLM
                     +--------------------------------------------------+
                                            |
                                            v  (HTTP, localhost)
                     +--------------------------------------------------+
                     | Rust redaction engine (sidecar binary)            |
                     |   POST /redact  -> aho-corasick + regex + optional|
                     |                    tract ONNX NER                |
                     |   POST /restore -> reverse-key apply (rarely used)|
                     |   GET  /healthz                                  |
                     +--------------------------------------------------+
```

**Why split:** The nginx worker is single-threaded; running regex/Ner inline in Lua
blocks every connection on that worker. The cosocket in `access` is a non-blocking
async I/O call (the worker yields while the sidecar computes). The sidecar, in contrast,
has its own thread pool and can run heavy regex / NER without blocking the proxy.

---

## 2. Plugin Manifest

```lua
-- kong/plugins/redact/schema.lua
local typedefs = require "kong.db.schema.typedefs"

return {
  name = "redact",
  protocols = typedefs.protocols_http,
  fields = {
    {
      config = {
        type = "record",
        required = true,
        fields = {
          { engine_url   = typedefs.url({ required = true, default = "http://127.0.0.1:8081" }) },
          { engine_timeout_ms = { type = "integer", default = 2000, between = { 100, 30000 } } },
          { pii_map_strategy = { type = "string", enum = { "ctx", "redis" }, default = "ctx" } },
          { redis = {
              type = "record",
              fields = {
                { host     = { type = "string", default = "redis-cluster.internal.net" } },
                { port     = { type = "integer", default = 6379 } },
                { db       = { type = "integer", default = 0 } },
                { password = { type = "string", referenceable = true } },
                { ssl      = { type = "boolean", default = false } },
                { ttl      = { type = "integer", default = 300 } },  -- seconds
              } } },
          { stream_mode  = { type = "string", enum = { "reject", "buffer", "passthrough" }, default = "buffer" } },
          { profile     = { type = "string", default = "pseudonym-llm" } },
          { on_error    = { type = "string", enum = { "closed", "open" }, default = "closed" } },
        },
      },
    },
  },
  entity_checks = {},
}
```

`PRIORITY = 1100` (must run after auth, before `ai-proxy`). Stored in `handler.lua`:

```lua
local RedactHandler = {
  PRIORITY = 1100,
  VERSION = "1.0.0",
}
```

---

## 3. Phases Hooked

| Phase | Action | Cosocket? | Sidecar call? |
|-------|--------|-----------|---------------|
| `access` | Buffer request body to EOF; call `POST /redact`; stash PII map | yes (allowed) | yes |
| `header_filter` | Clear `Content-Length` (only if redaction ran) | no | no |
| `body_filter` | Buffer response to EOF; local gsub restore from PII map | no (forbidden) | **no** : re-hydration is local string substitution |
| `log` | emit `redact.active`, `redact.placeholders_count`, `redact.engine.latency_ms` metrics | no | no |

No `rewrite`, no `response` phase (response phase would auto-enable buffered proxying
and forbid `header_filter`/`body_filter` in the same plugin : Kong refuses to start).

---

## 4. `access` Phase

```lua
function RedactHandler:access(conf)
  -- Read & buffer the full request body (chat completions are small; one chunk typically).
  local body = kong.service.request.get_raw_body()
  if not body or body == "" then return end

  -- Parse to find content strings to redact (OpenAI chat shape).
  local ok, parsed = pcall(cjson.decode, body)
  if not ok or not parsed.messages then
    -- Not a chat request; pass through. (Let upstream reject non-conformant bodies.)
    return
  end

  -- Streaming gate.
  if parsed.stream and conf.stream_mode == "reject" then
    return kong.response.exit(400, { error = "redact: streaming rejected; set stream_mode != reject" })
  end

  -- Sidecar call. cosocket is allowed in access; use the lua-resty-http client.
  local httpc = http.new()
  httpc:set_timeout(conf.engine_timeout_ms)
  local res, err = httpc:request_uri(conf.engine_url .. "/redact", {
    method = "POST",
    body = cjson.encode({
      messages = parsed.messages,
      profile  = conf.profile,
      stream   = parsed.stream or false,
    }),
    headers = {
      ["Content-Type"] = "application/json",
      ["X-Correlation-Id"] = kong.request.get_header("x-request-id") or "",
    },
  })
  httpc:set_keepalive()  -- pool the cosocket

  if not res then
    if conf.on_error == "closed" then
      return kong.response.exit(503, { error = "redact engine unreachable", detail = err })
    end
    kong.log.err("redact engine unreachable: ", err)
    return  -- fail open: forward unredacted (must emit X-Redact-Error header below)
  end
  if res.status ~= 200 then
    if conf.on_error == "closed" then
      return kong.response.exit(res.status, res.body, { ["Content-Type"] = "application/json" })
    end
    kong.log.err("redact engine non-200: ", res.status, " ", res.body)
    kong.response.set_header("X-Redact-Error", "engine-status-" .. res.status)
    return
  end

  local r_ok, redacted = pcall(cjson.decode, res.body)
  if not r_ok or not redacted.redacted_messages then
    if conf.on_error == "closed" then
      return kong.response.exit(502, { error = "redact engine malformed response" })
    end
    return
  end

  -- Replace the messages with redacted ones; rewrite the request body.
  parsed.messages = redacted.redacted_messages
  kong.service.request.set_raw_body(cjson.encode(parsed))

  -- Stash the PII map keyed by placeholder -> original. One merged dict across messages.
  -- (redacted_messages and redacted.key share positional order; the engine returns a
  -- single merged key map in redacted.key for v1; per-message keys supported in future.)
  local ctx = kong.ctx.plugin
  ctx.redact_key     = redacted.key            -- { [placeholder] = original }
  ctx.redact_active  = true
  ctx.redact_engine_latency_ms = tonumber(res.headers["X-Engine-Latency-Ms"]) or 0
  ctx.redact_placeholder_count = redacted.placeholder_count or 0

  -- Streaming mode buffering marker (for body_filter behaviour).
  ctx.redact_stream = parsed.stream and true or false

  -- Optional cross-worker durability mirror to Redis (only if strategy=redis).
  if conf.pii_map_strategy == "redis" and redacted.transaction_id then
    -- fire-and-forget; cosocket is a new guarded timer to avoid blocking access phase
    -- further. Falls back to ctx-only if redis is down (fail-open to ctx).
    pcall(function()
      local r = redis.new()
      r:set_timeout(200)
      local ok = r:connect(conf.redis.host, conf.redis.port)
      if ok then
        r:set("redact:tx:" .. redacted.transaction_id, cjson.encode(redacted.key), "EX", conf.redis.ttl)
        r:set_keepalive()
      end
    end)
  end
end
```

**Note on `lua-resty-http` and cosocket availability:** `httpc:request_uri` uses
`ngx.socket.tcp()` internally; this is **allowed in `access`** (one of the phases that
permits cosockets). It is forbidden in `header_filter`, `body_filter`, `log`. That is why
the sidecar call MUST happen in `access` and re-hydration MUST be local in `body_filter`.

---

## 5. `header_filter` Phase

```lua
function RedactHandler:header_filter(conf)
  local ctx = kong.ctx.plugin
  if not ctx.redact_active then return end
  -- Force chunked transfer so the body_filter rewrite (size may differ) is well-formed.
  -- Header values are already flushed by the time body_filter runs; clear here.
  kong.response.clear_header("Content-Length")
  -- Stamp cache/control signalling header for telemetry.
  kong.response.set_header("X-Redact-Active", "1")
end
```

`kong.response.clear_header("Content-Length")` is the canonical PDK wrapper for
`ngx.header.content_length = nil`. After clearing, nginx auto-downgrades to
`Transfer-Encoding: chunked`. **Do NOT set `Content-Length` or `Transfer-Encoding`
yourself** : nginx manages the latter.

---

## 6. `body_filter` Phase (Re-hydration)

**Cosocket is NOT available here.** Restoration is **local string substitution** against
the stashed PII map. The argus-redact precedent's `restore_with_key` is the canonical
implementation : copied verbatim with the safe-pattern escape requirement:

```lua
local function restore_with_key(text, key)
  if not key or not text then return text end
  local result = text
  for fake, original in pairs(key) do
    -- Plain (non-pattern) substitution; escape every non-word char in the placeholder
    -- so regex metacharacters in placeholders ([, ], etc.) are treated literally.
    local esc = fake:gsub("([^%w])", "%%%1")
    result = result:gsub(esc, original)
  end
  return result
end

function RedactHandler:body_filter(conf)
  local ctx = kong.ctx.plugin
  if not ctx.redact_active then return end

  local chunk, eof = ngx.arg[1], ngx.arg[2]

  if conf.stream_mode == "passthrough" and ctx.redact_stream then
    -- For streaming with passthrough, we CANNOT safely re-hydrate chunk-by-chunk
    -- because placeholders may straddle chunk boundaries. Either:
    --   (a) buffer-then-restore on EOF (default 'buffer' mode : see below), or
    --   (b) emit raw placeholder-laden chunks to the client (information leak risk;
    --       only acceptable if the client is trusted to re-hydrate). DEFAULT OFF.
    return  -- passthrough: emit unmodified (placeholders go to client). DANGEROUS.
  end

  -- Default: buffer-then-restore on EOF. Same pattern as argus-redact-bridge and the
  -- canonical OpenResty issue #1813 fix.
  ctx.redact_buffer = (ctx.redact_buffer or "") .. (chunk or "")
  if not eof then
    ngx.arg[1] = nil  -- swallow chunk; defer emission to EOF
    return
  end

  local full_body = ctx.redact_buffer
  -- For chat completions: parse the response body, restore each choice message.
  -- (OpenAI non-streaming: {choices:[{message:{content:...}}]} ; for streaming the
  -- buffered SSE body is `data: {…}\n\ndata: {…}\n…\ndata: [DONE]\n\n`.)
  local new_body
  if ctx.redact_stream then
    -- SSE buffer: do per-frame restore. Naive gsub over the whole SSE block is safe
    -- because placeholders never span SSE frames (the engine guarantees placeholders
    -- are atomic within produced tokens). For belt-and-braces, also gsub the buffer.
    new_body = restore_with_key(full_body, ctx.redact_key)
  else
    -- Non-streaming JSON: parse, restore choices, re-encode.
    local ok, parsed = pcall(cjson.decode, full_body)
    if ok and parsed.choices then
      for _, ch in ipairs(parsed.choices) do
        if ch.message and ch.message.content then
          ch.message.content = restore_with_key(ch.message.content, ctx.redact_key)
        end
      end
      new_body = cjson.encode(parsed)
    else
      new_body = restore_with_key(full_body, ctx.redact_key)  -- fallback: whole-body gsub
    end
  end

  ngx.arg[1] = new_body
  ngx.arg[2] = true  -- mark EOF (one-shot emission)
  ctx.redact_buffer = nil
end
```

**Cross-chunk placeholder safety:** The engine MUST guarantee placeholders are
token-monotonic (a placeholder never spans a token boundary in the produced SSE
stream). Since the engine produces placeholders itself and replacements happen at the
PLACEHOLDER level (not character level), an LLM cannot split a placeholder across SSE
frames unless the LLM itself emits the placeholder text char-by-char : extremely unlikely
for `[CUSTOMER_NAME_1]`-style fixed tokens. For full safety, the SSE buffer is also
gsubs'd wholesale in the streaming branch, which is always correct because the buffer
contains the full concatenated SSE.

---

## 7. `log` Phase

Emit metrics for billing/telemetry correlation. The redaction-enforced counts feed into
the audit log alongside the `ai.proxy.usage.*` fields:

```lua
function RedactHandler:log(conf)
  local ctx = kong.ctx.plugin
  if not ctx.redact_active then return end
  kong.log.set_serialize_value("redact.active", true)
  kong.log.set_serialize_value("redact.placeholder_count", ctx.redact_placeholder_count or 0)
  kong.log.set_serialize_value("redact.engine_latency_ms", ctx.redact_engine_latency_ms or 0)
  kong.log.set_serialize_value("redact.stream", ctx.redact_stream or false)
  -- X-Redact-Active response header is also serialised by default via kong.response
end
```

These three fields ride the standard Kong log payload (consumed by `http-log` /
`tcp-log` plugin to Vector → ClickHouse). The billing ledger schema in `PROPOSAL-LLM-
GATEWAY-v2.md` Section 5.3 already absorbs them as part of the audit trail; per the
Revised Proposal's billing-grade contract. Add to the `llm_billing_ledger` schema:

```sql
ALTER TABLE llm_billing_ledger
  ADD COLUMN redact_active Bool DEFAULT false,
  ADD COLUMN redact_placeholder_count UInt32 DEFAULT 0,
  ADD COLUMN redact_engine_latency_ms UInt32 DEFAULT 0,
  ADD COLUMN redact_stream Bool DEFAULT false;
```

---

## 8. Filter Ordering (with auth, failover, cache)

Recommended filter chain order on the LLM chat route:

```
[ auth-oidc | auth-ldap ]  ->  redact (Lua, PRIORITY=1100)
                              ->  semantic-cache or failover (Proxy-Wasm)
                              ->  ai-proxy (Kong OSS)
```

Kong runs Lua plugins in PRIORITY order (higher first) and Wasm filters in chain order
after Lua. `auth-*` must run before `redact` (so the redact engine can be tenant-aware in
future). `redact`'s PRIORITY=1100 places it above the `ai-proxy` plugin's default
PRIORITY (≈ 750) and below `openid-connect` (Enterprise, PRIORITY=1000).

On the **failover** layer's `send_http_response` short-circuit (cache HIT or proxied
response via `dispatch_http_call`), the `redact` plugin's `body_filter` will still fire
on the synthesized response ONLY if Kong runs Lua plugins on locally-generated responses
: verify per Kong version. SAFER: the cache/failover plugin, on cache HIT, must call
the redaction engine's `POST /restore` endpoint via `dispatch_http_call` before
`send_http_response`. Specified in `PLUGIN-SEMANTIC-CACHE.md` Section E.4.

---

## 9. Streaming Mode Decision Matrix

| `stream_mode` | Streaming request behavior |
|---------------|----------------------------|
| `reject` | 400 immediately if `stream:true` |
| `buffer` (default) | Forward `stream:true` upstream; **buffer the SSE stream to EOF in body_filter**; restore once; flush as a single chunk. Breaks per-token streaming UX (client sees whole response at once). |
| `passthrough` | Emit chunks unmodified; **placeholders pass through to client** (re-hydration skipped). Only acceptable if the client is trusted/internal and re-hydrates. DANGEROUS default-off. |

**Future enhancement (v2):** Implement the `parse-sse-chunk` +
per-frame-restore-then-flush pattern from Kong's `kong/llm/plugin/shared-filters` to
preserve per-token streaming UX without breaking cross-chunk placeholders. This requires
parsing `data: {…}\n\n` frames inside the Lua buffer and restoring per frame before
emitting : non-trivial but proven in `kong/llm/plugin/shared-filters/normalize-sse-chunk.lua`.

---

## 10. Security Constraints

- **Sidecar mTLS:** the HTTP leg to `redact-engine:8081` runs on localhost (same pod)
  or via a private cluster network. If non-localhost, mTLS is mandatory : the sidecar
  validates Kong's client cert and rejects unauthenticated callers. The PII map and
  original PII never traverse a public network.
- **No PII in logs:** the sidecar MUST NOT log original PII. The Lua plugin MUST NOT log
  `ctx.redact_key` (it's referenced only for substitution, never stringified in
  `kong.log.err`). The `log` phase metric `redact.placeholder_count` is the count, not
  the contents.
- **No silent fallback:** `on_error: closed` (default) returns 503 if the engine is
  unreachable. `on_error: open` forwards unredacted BUT emits `X-Redact-Error` header +
  error metric. **Never** silently 200. **Never** silently forward PII to upstream.
- **Strip `X-Redact-Error` header** before egress to upstream LLM providers (the
  failover plugin handles this in its header-strip list).

---

## 11. Failure Modes

| Failure | Detection | `on_error=closed` behavior | `on_error=open` behavior |
|---------|-----------|----------------------------|---------------------------|
| Engine unreachable (cosocket refused) | `request_uri` returns nil,err | 503 | forward unredacted + `X-Redact-Error: unreachable` |
| Engine timeout (`engine_timeout_ms`) | `httpc:set_timeout` fires | 503 | forward unredacted + `X-Redact-Error: timeout` |
| Engine 5xx | `res.status >= 500` | forward engine status/body | forward unredacted + `X-Redact-Error: engine-5xx` |
| Engine 4xx | `res.status` is 4xx | forward engine status (likely client misconfig) | forward engine status |
| Engine malformed JSON | `cjson.decode` fails | 502 | forward unredacted + `X-Redact-Error: malformed` |
| Request not chat-shaped | `parsed.messages == nil` | passthrough (no redaction, no error) | passthrough |
| Empty response body from upstream | `body == ""` on EOF | emit empty body | empty body |
| `body_filter` gsub fails | pcall wrap | log + emit raw `full_body` (placeholders to client!) : alerting | same |
| Redis mirror write fails (strategy=redis) | pcall returns false | log + fall back to ctx-only (durability degraded) | same |

The `on_error=closed` default is the production posture per AGENTS.md Rule 13.
`open` is provided for degraded-mode ops where unredacted traffic to a private tenant
LLM is temporarily acceptable (must be a deliberate per-route opt-in, never a global
default).

---

## 12. Configuration Example (decK)

```yaml
plugins:
  - name: redact
    config:
      engine_url: "http://redact-engine.sidecar.svc.cluster.local:8081"
      engine_timeout_ms: 2000
      pii_map_strategy: ctx           # per-stream kong.ctx.plugin
      stream_mode: buffer             # default
      profile: pseudonym-llm
      on_error: closed                # 503 on engine failure (production default)
```

---

## 13. Test Plan (Required)

- Unit: `restore_with_key` with patterns containing `[]`, `%`, parens : must escape
  metacharacters and not double-substitute.
- Integration: end-to-end with the redact-engine sidecar running; assert placeholders in
  upstream call, originals in client response.
- Stream-mode matrix: `reject` (400), `buffer` (defers to EOF, single emission),
  `passthrough` (placeholders pass through).
- Failure injection: kill redact-engine → assert 503 (`closed`) / unredacted pass +
  `X-Redact-Error` (`open`).
- Header: assert `Content-Length` cleared; assert downstream receives chunked transfer.
- No silent fallback: assert NO request ever proceeds without either redaction or an
  explicit `X-Redact-Error` header surfaced.

---

## 14. Open Questions Carried to Engine Spec

| Q | Resolution in `PLUGIN-REDACT-ENGINE.md` |
|---|----------------------------------------|
| Placeholder format | `[CUSTOMER_NAME_1]` etc. : defined by `profile` |
| Numbering namespace | Per-message (collapsed during merge) or per-stream |
| Streaming placeholder atomicity | Engine guarantees placeholders are unbreakable in produced tokens |
| NER inline vs sidecar-to-sidecar | Engine config; inline tract is allowed because sidecar has its own thread pool |
| Cross-tenant key isolation | Not applicable : engine receives messages only; tenant claims already stripped upstream of redaction (redact runs after auth) |

---

## 15. References

- argus-redact-bridge (precedent): https://github.com/wan9yu/kong-plugin-argus-redact
- argus-redact engine (Python+PyO3+Rust): https://github.com/wan9yu/argus-redact
- Kong `ai-sanitizer` (external PII service contract): https://developer.konghq.com/plugins/ai-sanitizer/
- lua-nginx-module cosocket ban in `body_filter`/`header_filter`: https://github.com/openresty/lua-nginx-module#body_filter_by_lua
- openresty/lua-nginx-module issue #1813 (Content-Length clear + buffer-then-rewrite): https://github.com/openresty/lua-nginx-module/issues/1813
- `kong.ctx.plugin` lifetime: https://docs.konghq.com/gateway/latest/plugin-development/pdk/kong.ctx/
- Kong `header_filter`/`response` phase mutual exclusion: https://developer.konghq.com/custom-plugins/handler.lua/
- Kong ai-proxy SSE shared filters (`parse-sse-chunk` / `normalize-sse-chunk`): `Kong/kong` `kong/llm/plugin/shared-filters/normalize-sse-chunk.lua`

---

**End of document.**