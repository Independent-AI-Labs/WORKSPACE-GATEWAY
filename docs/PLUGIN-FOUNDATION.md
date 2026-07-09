# Plugin Foundation Specification - APISIX Custom Lua Plugin Development

**Document ID:** AMI-PROP-LLMGW-PLUGIN-FOUNDATION-v2.0
**Status:** Draft
**Date:** 2026-07-05
**Parent:** `PROPOSAL-LLM-GATEWAY-v3.md`
**Scope:** Shared engineering foundation for custom Lua plugins running inside
Apache APISIX 3.17.0. This document is the authoritative base; each per-plugin
spec inherits these contracts and adds its own schema, phase logic, and config.

---

## 1. Target Platform

| Component | Version | Rationale |
|-----------|---------|-----------|
| Apache APISIX | 3.17.0 (`apache/apisix:3.17.0-debian`) | All plugins OSS, no license enforcement, Docker images for every version, source code public |
| OpenResty / LuaJIT | bundled with APISIX image | Same OpenResty phase model and cosocket semantics as Kong |
| Standalone YAML mode | `deployment.role: data_plane`, `config_provider: yaml` | File-driven hot reload, no etcd/PostgreSQL needed for gateway config |
| Lua | LuaJIT 2.1 (bundled) | JIT-compiled hot traces; `ngx.re` PCRE bindings are native C |

**No Wasm, no Rust Proxy-Wasm, no `dispatch_http_call`.** All custom logic is pure Lua
running in-process inside the nginx worker. Network I/O uses non-blocking cosockets
(`lua-resty-http`, `lua-resty-redis`).

---

## 2. Custom Plugin Structure

### 2.1 File layout

```
WORKSPACE-GATEWAY/
  plugins/
    custom/
      redact.lua              # PLUGIN-REDACT-LUA
      semantic-cache.lua      # PLUGIN-SEMANTIC-CACHE
  conf/
    config.yaml               # APISIX config (extra_lua_path, plugins list)
    apisix.yaml               # standalone YAML routes + plugin configs
    redact-patterns.yaml      # file-based PII patterns + dictionary (loaded by redact plugin)
```

### 2.2 Plugin manifest

Every custom plugin returns a Lua table with these required fields:

```lua
local core = require("apisix.core")

local _M = {
    version = 0.1,
    priority = 2500,           -- higher runs first; auth built-ins are ~2599
    name = "redact",
}
```

### 2.3 Plugin loading via `extra_lua_path`

In `conf/config.yaml`:

```yaml
apisix:
  extra_lua_path: "/usr/local/apisix/apisix/plugins/custom/?.lua;"

plugins:
  - redact
  - semantic-cache
```

APISIX scans the `plugins` list at startup. Each listed name must resolve via
`extra_lua_path` to `apisix/plugins/custom/<name>.lua` (the `require` path is
`apisix.plugins.custom.<name>`).

### 2.4 Custom Docker image

```dockerfile
FROM apache/apisix:3.17.0-debian
COPY plugins/custom/ /usr/local/apisix/apisix/plugins/custom/
COPY conf/config.yaml /usr/local/apisix/conf/config.yaml
COPY conf/apisix.yaml /usr/local/apisix/conf/apisix.yaml
COPY conf/redact-patterns.yaml /etc/apisix/redact-patterns.yaml
```

Standalone YAML mode: `apisix.yaml` is polled every 1 second for changes.
No Admin API writes needed for config updates.

---

## 3. Plugin Schema

APISIX uses Lua table schemas (not JSON Schema). Define a `schema` field and
a `check_schema` function:

```lua
_M.schema = {
    type = "object",
    properties = {
        patterns_file = { type = "string", default = "/etc/apisix/redact-patterns.yaml" },
        stream_mode   = { type = "string", enum = { "reject", "buffer", "passthrough" }, default = "buffer" },
        on_error      = { type = "string", enum = { "closed", "open" }, default = "closed" },
    },
}

function _M.check_schema(conf)
    return core.schema.check(_M.schema, conf)
end
```

`core.schema.check` validates the config table against the schema at route-load
time. Invalid config is rejected before any request hits the route.

---

## 4. Phase Mapping

APISIX plugins implement phase functions. Same OpenResty phases, same
cosocket availability rules as Kong:

| Phase function | Nginx phase | Cosocket? | Can yield? | Notes |
|----------------|-------------|-----------|------------|-------|
| `_M.access(conf, ctx)` | access (rewrite+access) | yes | yes | Main logic phase: auth checks, body modification, sidecar calls, cache lookups |
| `_M.header_filter(conf, ctx)` | header_filter | no | no | Response header mutation only; clear `Content-Length` here before body_filter |
| `_M.body_filter(conf, ctx)` | body_filter | no | no | Response body chunk processing; local string ops only (gsub, concat) |
| `_M.log(conf, ctx)` | log | no (direct) | via `ngx.timer.at` | Emit metrics/telemetry; cosockets only inside `ngx.timer.at` callback |

**Cosocket rule (identical to Kong/OpenResty):** `lua-resty-http` and
`lua-resty-redis` use `ngx.socket.tcp()` internally. This is **allowed in
`access`** and **forbidden in `header_filter` and `body_filter`**. In `log`,
use `ngx.timer.at` to get a yieldable context for cosocket calls.

---

## 5. Request / Response APIs

### 5.1 Reading the request body (access phase)

```lua
function _M.access(conf, ctx)
    core.request.read_body(ctx)
    local body = core.request.get_body(ctx)
    if not body or body == "" then return end
    -- parse, modify, rewrite...
end
```

Alternatively: `ngx.req.read_body()` then `ngx.req.get_body_data()`.

### 5.2 Modifying the request body (access phase)

```lua
local modified = cjson.encode(parsed)
ngx.req.set_body_data(modified, #modified)
-- or set header:
core.request.set_header(ctx, "X-Redact-Active", "1")
```

### 5.3 Response headers (header_filter)

```lua
function _M.header_filter(conf, ctx)
    if not ctx.redact_active then return end
    core.response.set_header(ctx, "Content-Length", nil)  -- clear for chunked
    core.response.set_header(ctx, "X-Redact-Active", "1")
end
```

Alternatively: `ngx.header["Content-Length"] = nil`.

### 5.4 Response body chunks (body_filter)

```lua
function _M.body_filter(conf, ctx)
    if not ctx.redact_active then return end
    local chunk, eof = ngx.arg[1], ngx.arg[2]
    -- buffer chunks until EOF, then restore and emit
    ctx.redact_buffer = (ctx.redact_buffer or "") .. (chunk or "")
    if not eof then
        ngx.arg[1] = nil  -- swallow chunk
        return
    end
    ngx.arg[1] = restore_with_key(ctx.redact_buffer, ctx.redact_key)
    ngx.arg[2] = true
    ctx.redact_buffer = nil
end
```

### 5.5 Short-circuit response (access phase)

Returning a non-nil value from `access()` sends the response immediately:

```lua
function _M.access(conf, ctx)
    if cache_hit then
        return 200, cached_body  -- APISIX sends this; no upstream call
    end
    if auth_failed then
        return 401, { error = "invalid_token" }
    end
end
```

For more control (custom headers, content-type):

```lua
core.response.set_header(ctx, "Content-Type", "text/event-stream")
return 200, sse_body
```

---

## 6. Context and State

### 6.1 Per-request context: `ctx` table

The `ctx` table is passed to every phase function for the same request. It is
shared across all plugins. Use a unique prefix to avoid collisions:

```lua
ctx.redact_key = { ["[EMAIL_1]"] = "john@example.com" }
ctx.redact_active = true
ctx.cache_status = "MISS"
```

This replaces Kong's `kong.ctx.plugin` namespacing. Convention: use
`ctx.<plugin_name>_*` prefix for per-plugin fields.

### 6.2 Cross-worker shared state: `ngx.shared.DICT`

Declared in `config.yaml`:

```yaml
nginx_config:
  http:
    lua_shared_dict:
      redact_state: 1m
      semcache_state: 4m
```

Atomic operations (same as Kong shdict):

```lua
local shm = ngx.shared.redact_state
shm:set("key", "value", 300)       -- TTL 300s
local val = shm:get("key")
shm:incr("counter", 1, 0)          -- atomic increment, default 0
local ok, err = shm:cas("key", oldval, newval, 0.001)  -- CAS (if available)
```

### 6.3 Off-thread work: `ngx.timer.at`

For async, non-blocking background tasks (NER sidecar calls, cache storage):

```lua
ngx.timer.at(0, function(premature)
    if premature then return end
    -- cosockets are available here
    local httpc = http.new()
    local res = httpc:request_uri("http://127.0.0.1:8081/ner", { ... })
end)
```

The timer runs in a yieldable context. The request thread is NOT blocked.

---

## 7. Network I/O (Cosockets)

### 7.1 HTTP calls: `lua-resty-http`

```lua
local http = require("resty.http")
local httpc = http.new()
httpc:set_timeout(conf.timeout_ms)
local res, err = httpc:request_uri(url, {
    method = "POST",
    body = body,
    headers = { ["Content-Type"] = "application/json" },
})
httpc:set_keepalive()  -- pool the cosocket
```

Non-blocking: the nginx worker handles other requests while awaiting the
response. Synchronous-looking code via Lua coroutines. Available in `access`
and `ngx.timer.at` callbacks only.

### 7.2 Redis: `lua-resty-redis`

```lua
local redis = require("resty.redis")
local red = redis:new()
red:set_timeout(500)
local ok, err = red:connect("127.0.0.1", 6379)
-- FT.SEARCH with vector similarity (Redis VSS)
local res, err = red:do_raw("FT.SEARCH idx:semcache "
    .. "\"(@tenant:{tenant-123})=>[KNN 1 @embedding $qvec AS distance]\" "
    .. "PARAMS 2 qvec " .. vector_blob .. " LIMIT 0 1 DIALECT 2")
red:set_keepalive()
```

For binary protocol commands (FT.SEARCH PARAMS with float32 blobs), use
`red:do_raw()` or the raw `REDIS` command interface. The vector blob must be
packed as little-endian FLOAT32 via `ffi.new` + `ffi.string`.

### 7.3 Keepalive and connection pools

Both `lua-resty-http` and `lua-resty-redis` support `set_keepalive()` which
returns the connection to a pool for reuse. Always call after each request.
Default pool size: 10 connections per worker.

---

## 8. Error Handling Discipline

Per AGENTS.md Rule 13: **no silent error swallowing, no silent fallbacks.**

| Outcome | Behavior |
|---------|----------|
| Sidecar unreachable / timeout | Log `core.log.error(...)` + return `503` with error body |
| Redis down / query error | Log + emit `X-Cache-Error` response header + MISS (cache plugin) or 503 (auth plugin) |
| Malformed response from sidecar | Log + return `502` with error body |
| Config parse failure | `check_schema` returns false at route-load time; route rejected |
| Body parse failure (cjson decode) | Log + emit `X-<Plugin>-Warning` header; pass through unmodified |
| Auth denial | Return `401` with `WWW-Authenticate: Bearer` (or `403` for scope/aud) |

**Never** silently 200. **Never** silently `Continue` with degraded state.
Every error surfaces a non-2xx or a `X-*-Error` / `X-*-Warning` header.

---

## 9. Plugin Ordering Convention

APISIX runs plugins in `priority` order (higher first). Recommended priorities:

| Plugin | Priority | Rationale |
|--------|----------|-----------|
| `openid-connect` | ~2599 | Built-in; auth must run first |
| `ldap-auth` | ~2599 | Built-in; auth must run first |
| `semantic-cache` | 2550 | On HIT, short-circuit before redaction/ai-proxy |
| `redact` | 2500 | After auth, before ai-proxy |
| `ai-proxy-multi` | ~2402 | Built-in; routes to provider |
| `ai-proxy` | ~2402 | Built-in; format translation |
| `limit-count` | 2002 | Built-in; fixed-window rate limiting, per-key via var key |
| `proxy-buffering` | ~2800 | Built-in; sets nginx directive (high priority) |
| `http-logger` | ~410 | Built-in; log phase |
| `prometheus` | ~500 | Built-in; metrics |

Custom plugins set their own priority in the manifest `_M.priority`.

---

## 10. Per-Plugin Doc Index

| Document | Plugin | Type | Version |
|----------|--------|------|---------|
| `PLUGIN-REDACT-LUA.md` | PII redaction + re-hydration | Custom Lua | v1 |
| `PLUGIN-SEMANTIC-CACHE.md` | Redis VSS semantic cache | Custom Lua + Rust sidecar | v2 |
| `PLUGIN-REDACT-ENGINE.md` | Optional NER sidecar (Rust) | Rust binary | v2 |
| `BUILTIN-PLUGINS.md` | APISIX built-in plugin config guide | Configuration | v1 |

See `README.md` in this directory for the full docs index and reading order.

**End of document.**
