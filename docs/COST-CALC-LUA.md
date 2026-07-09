# Cost Calculator Module Specification - APISIX Custom Lua Module

**Document ID:** AMI-PROP-LLMGW-COST-CALC-LUA-v1.2
**Status:** Draft (revised - live-verified 2026-07-07; deployment gaps documented in §18)
**Date:** 2026-07-07
**Parent:** `PROPOSAL-LLM-GATEWAY-v3.md`; inherits `PLUGIN-FOUNDATION.md`
**Companion:** `PLUGIN-REDACT-LUA.md`, `PLUGIN-SEMANTIC-CACHE.md`

**v1.2 changes vs v1.1:** Added §18 (Known Deployment Gaps and Technical
Debt) documenting 9 issues found during live verification: Dockerfile
missing COPY for `cost_calc.lua` and `key-meta.lua` (§18.1), no volume
mount for `plugins/custom/` (§18.2), pricing key collision causing 14%
overcharge (§18.3), no error handling in `plugin.init()` warmup call
(§18.4), dashboard v27 not deployed to running Grafana (§18.5), dead code
in `compute_cost` (§18.6), `cost_calc` not in `config.yaml` plugins list
(§18.7), no end-to-end integration test (§18.8), no ClickHouse migration
script (§18.9). Updated §3 Module Manifest to match actual lazy-require
implementation. Updated §5.3 with live-verified worked example. Updated
§11.4 with actual live verification results. Updated §14 Q5 with collision
findings. Updated §16 Implementation Checklist with actual completion
status.

**v1.1 changes vs v1.0:** Corrected `plugin.init_worker()` → `plugin.init()`
(APISIX `plugin.lua:263` calls `init`, not `init_worker`); documented
`resty.http` availability and the cosocket limitation that makes
`ngx.timer.at` mandatory; removed `models_dev_url` from the plugin schema
(`plugin.init()` receives no `conf`); added §17 (Verified APISIX Runtime
Facts appendix); corrected deployment path (flat, no `custom/` subdir).

This document specifies a pure Lua module (`cost_calc.lua`) that the existing
`sse-usage` plugin calls during the `log` phase to populate the `cost` and
`cost_source` columns of `llm_gateway.usage_log`. The module resolves per-request
cost via **one of two deterministic pathways** (an `if / else` branch - explicitly
NOT a fallback chain):

- **Pathway A - upstream-reported cost**: the SSE stream emitted a chunk with a
  strictly positive cost value (`obj.cost` or `usage.estimated_cost`).
- **Pathway B - locally computed cost**: the SSE stream reported zero cost and
  the gateway multiplies the captured token counts by per-model pricing pulled
  from `https://models.dev/api.json`.

A third, fully labeled state - `cost_source = 'unknown'` - exists for the case
where Pathway B is taken but the model is not present in models.dev (or pricing
data is unavailable). This is **not** a fallback: it is an explicit, queryable
"no pricing data" state with `cost = 0`. The gateway never silently zeros out
a row; the source column always records why a value was written.

---

## 1. Background and Rationale

### 1.1 The problem

`sse-usage` already extracts `cost` from SSE chunks. For some upstream providers
(notably `opencode.ai` relaying `glm-5.1`) the stream contains an
`x-opencode-type: inference-cost` chunk with a real cost string
(`"cost":"0.00024100"`). For other providers (notably `opencode.ai` relaying
`frank/GLM-5.2`) the stream contains only `"cost":"0"` and
`"estimated_cost": 0.0`. The gateway stores `0` faithfully, which is correct
**as an upstream echo** but useless for observability: the dashboard's
"TOTAL COST" tile shows `$0` even though the same model is reported as
`$14.86` by opencode's own UI.

### 1.2 How opencode does it

opencode's `Session.getUsage` (`packages/opencode/src/session/session.ts:338`)
performs the cost calculation **client-side**:

```ts
cost = Decimal(0)
  .add(tokens.input        * costInfo.input        / 1e6)
  .add(tokens.output       * costInfo.output       / 1e6)
  .add(tokens.cache.read   * costInfo.cache.read   / 1e6)
  .add(tokens.cache.write  * costInfo.cache.write  / 1e6)
  .add(tokens.reasoning    * costInfo.output       / 1e6)   // reasoning billed at output rate
```

The `costInfo` is the per-model entry from `https://models.dev/api.json`, which
publishes `{input, output, cache_read, cache_write, ...}` as USD per million
tokens. opencode caches the JSON for 5 minutes and refreshes every 60 minutes
(`packages/core/src/models-dev.ts:143`).

### 1.3 Why the gateway should do it too

The gateway is the only component that sees **every** request from every
client. opencode's per-session cost is correct for a single user but invisible
to operators. Computing cost at the gateway:

- produces a single source of truth across all clients (opencode, curl, third-party);
- survives client crashes (the cost row is in ClickHouse, not in-memory);
- enables per-key, per-model, per-time-window cost dashboards without client cooperation;
- keeps the same math opencode uses, so cross-checking the two is trivial.

---

## 2. Architecture

```
                                 APISIX worker (LuaJIT, in-process)
+-------------------------------------------------------------------------------------------------+
|                                                                                                 |
|  plugin.init() (once per worker, called by APISIX plugin.lua:263):                             |
|    cost_calc.warmup()  ────►  ngx.timer.at(0, fetch_and_cache)   ← cosocket-capable context     |
|                                   │                                                             |
|                                   ▼                                                             |
|                          resty.http GET https://models.dev/api.json                             |
|                                   │                                                             |
|                                   ▼                                                             |
|                          flatten + write to ngx.shared.dict "gateway-cache"                     |
|                          keys: "pricing:<model_id>"  ─► {input, output, cache_read,             |
|                                                          cache_write, reasoning}                |
|                          key:  "pricing:ts"          ─► unix_seconds                             |
|                                                                                                 |
|  sse-usage.log (per request, after SSE stream finishes):                                       |
|    tokens  = sse_lib.extract_tokens(ctx.sse_usage)   ──► pt, ct, tt, cached, reasoning          |
|    sse_cost = ctx.sse_cost                            ──► 0 or >0 from upstream                  |
|    req_model = ctx.sse_req_model                      ──► "glm-5.2" (request body, canonical)   |
|                                                                                                 |
|    ┌────────────────────────────────────────────────────────────────────────────────────────┐    |
|    │  if sse_cost > 0 then                                                                  │    |
|    │      final_cost, source = sse_cost, "upstream"             ── Pathway A                 │    |
|    │  else                                                                                  │    |
|    │      price = cost_calc.get_pricing(req_model)              ── shared.dict lookup        │    |
|    │      if price then                                                                     │    |
|    │          final_cost = cost_calc.compute_cost(tokens, price)                            │    |
|    │          source    = "computed"                            ── Pathway B (success)        │    |
|    │      else                                                                              │    |
|    │          final_cost = 0                                                                │    |
|    │          source    = "unknown"                             ── Pathway B (no pricing)    │    |
|    │      end                                                                               │    |
|    │  end                                                                                   │    |
|    └────────────────────────────────────────────────────────────────────────────────────────┘    |
|                                                                                                 |
|    INSERT INTO llm_gateway.usage_log                                                            |
|        (..., cost, cost_source) VALUES (..., final_cost, source_enum)                           |
|                                                                                                 |
+-------------------------------------------------------------------------------------------------+
                                   │
                                   ▼
                           ClickHouse usage_log
                           columns: cost Float64,
                                    cost_source Enum8('upstream'=0,'computed'=1,'unknown'=2)
```

**Why shared dict, not a Lua module-level table:**
APISIX runs multiple nginx workers, each with its own Lua VM. A module-level
table is per-worker; on a worker restart the table is cold. `ngx.shared.dict`
is shared across all workers in the process, survives single-worker crashes,
and provides atomic `get`/`set`/`ttl` operations. It is the canonical APISIX
primitive for cross-worker state (used by `limit-req`, `limit-count`, etc.).

**Why async fetch via `ngx.timer.at`, not synchronous in `plugin.init()`:**
OpenResty **disables cosockets** in the `init_worker_by_lua*` context (and
therefore in `plugin.init()`, which runs in that context - see §17.4). A
direct `resty.http` call in `plugin.init()` fails with
`API disabled in the context of init_worker_by_lua*`. The standard OpenResty
workaround is `ngx.timer.at(0, handler)`: the timer callback runs in a
cosocket-capable context, so `resty.http` works there. This is a hard
OpenResty constraint, not a design preference. The request path never blocks
on a fetch - `get_pricing()` is a synchronous shared-dict lookup (~µs).

---

## 3. Module Manifest

```lua
-- plugins/custom/cost_calc.lua   (repo source path)
-- Deployed to: /usr/local/apisix/apisix/plugins/cost_calc.lua  (flat, no custom/ subdir)
-- Required as: require("apisix.plugins.cost_calc")
-- Pure module, NOT an APISIX plugin. Required by sse-usage.lua in init() and log phase.
-- No plugin = no schema, no priority, no phase bindings.
--
-- Dependency strategy: APISIX/OpenResty-specific modules (apisix.core,
-- cjson.safe, resty.http) and the ngx global are lazy-required inside the
-- functions that use them, NOT at module top level. This keeps compute_cost
-- and resolve_cost (upstream + unknown branches) loadable and runnable in
-- plain LuaJIT without the nginx worker runtime, so the unit test suite
-- (tests/config/test_cost_calc.sh) runs with zero dependency injection.

local M = {}

local SHARED_DICT = "gateway-cache"        -- configured in conf/config.yaml → custom_lua_shared_dict
local PRICING_KEY_PREFIX = "pricing:"      -- pricing:<model_id>
local TS_KEY = "pricing:ts"                -- last successful fetch (unix seconds)
local LOCK_KEY = "pricing:lock"            -- fetch lock (NX + 30s expiry)
local TTL_SECONDS = 3600                   -- 1 hour fresh
local STALE_SECONDS = 86400                -- 24 hours usable-if-fetch-fails
local DEFAULT_URL = "https://models.dev/api.json"
local FETCH_TIMEOUT = 10000
local LOCK_TTL = 30

M.TTL_SECONDS = TTL_SECONDS
M.STALE_SECONDS = STALE_SECONDS
M.SOURCE_UPSTREAM = "upstream"
M.SOURCE_COMPUTED = "computed"
M.SOURCE_UNKNOWN = "unknown"

-- Lazy accessors (NOT top-level requires - see dependency strategy above)
local function get_dict()
    if not ngx or not ngx.shared then return nil end
    return ngx.shared[SHARED_DICT]
end

local function get_core()
    return require("apisix.core")
end

return M
```

The module exposes five functions (`warmup`, `fetch_and_cache`,
`get_pricing`, `compute_cost`, `resolve_cost`) plus the three source-string
constants. No globals are touched. No APISIX plugin metadata is declared -
this is a library, not a plugin.

**Lazy requires rationale:** `apisix.core`, `cjson.safe`, and `resty.http`
are `require()`-d *inside* the functions that use them, not at module top
level. The `ngx` global is guarded in `get_dict()` (`if not ngx or not
ngx.shared then return nil end`). This means `compute_cost` (pure Lua math)
and `resolve_cost`'s upstream + unknown branches run in plain LuaJIT with
no nginx runtime, no injected globals, no preloaded modules - the unit test
suite runs with zero dependency injection (see §11.3).

**Deployment note:** APISIX loads plugins/modules from
`/usr/local/apisix/apisix/plugins/`. There is no `custom/` subdirectory in
the deployed tree - the `plugins/custom/` path in this repo is a source
organization choice only. Deployment copies the file to the flat plugins
directory (see §17.2). The `require("apisix.plugins.cost_calc")` path works
because APISIX's Lua package path includes
`/usr/local/apisix/apisix/plugins/?.lua` (via the `?.lua` →
`apisix/plugins/cost_calc.lua` resolution under `extra_lua_path` or the
default install tree).

**WARNING - deployment gap (see §18.1):** `cost_calc.lua` and `key-meta.lua`
are NOT in `res/docker/Dockerfile.apisix` COPY directives, and the
`plugins/custom/` directory is NOT volume-mounted in
`res/docker/docker-compose.yml`. The current deployment relies on manual
`podman cp`. An image rebuild or container recreation will lose these
files. This must be fixed before the work is maintainable.

---

## 4. Public API

### 4.1 `M.warmup(models_dev_url?)`

Called from the `sse-usage` plugin's `init()` hook (see §6.1). `plugin.init()`
runs once per worker during APISIX's plugin-load phase
(`apisix/plugin.lua:263`), inside the `init_worker_by_lua*` Nginx context.
That context **does not permit cosockets**, so `warmup()` itself cannot call
`resty.http` directly - it only spawns an `ngx.timer.at(0, fetch_and_cache)`,
whose callback runs in a cosocket-capable context. Idempotent: if a fetch is
already in flight (guarded by the shared-dict lock key `pricing:lock`),
returns immediately.

| Parameter | Type | Default | Notes |
|-----------|------|---------|-------|
| `models_dev_url` | string | `"https://models.dev/api.json"` | Passed by caller; `plugin.init()` has no `conf`, so the default is always used in v1 |

Returns: `true` on timer spawn, `nil, err` on failure. The fetch result itself
is observable via `M.get_pricing()` after the timer fires.

### 4.2 `M.fetch_and_cache(models_dev_url?)`

The actual fetch routine, safe to call from any `ngx.timer.at` callback
(which is the only context where `resty.http` cosockets work during startup
- see §17.4). Reads the `models.dev/api.json` payload, flattens it into
per-model pricing entries, writes each to the shared dict with a TTL, and
updates `pricing:ts`.

| Step | Action |
|------|--------|
| 1 | Acquire shared-dict lock key `pricing:lock` (`shared_dict:add(LOCK_KEY, "1", 0, 30)` - atomic NX with 30s expiry). Bail if already held. |
| 2 | `local httpc = http.new(); httpc:set_timeout(10000); local res, err = httpc:request_uri(models_dev_url, {method="GET"})`. `resty.http` is at `/usr/local/apisix/deps/share/lua/5.1/resty/http.lua` (§17.1). |
| 3 | On non-200 or JSON decode failure: log `core.log.warn`, leave existing cache intact (stale-if-error per §7), release lock (`shared_dict:delete(LOCK_KEY)`), return `nil, err`. |
| 4 | Iterate top-level providers (`data[provider_id]`), then `provider.models[model_id]`. For each model with a non-empty `cost` object (verified shape in §17.6): |
| 5 | Normalize key: `model_id` lowercased; if contains `/`, take the suffix (e.g. `frank/GLM-5.2` → `glm-5.2`). |
| 6 | Build pricing object (§4.4) and `shared_dict:set("pricing:" .. key, cjson.encode(price), STALE_SECONDS)`. Omit `reasoning` key when models.dev has none (so `nil`-coalesce in `compute_cost` works). |
| 7 | `shared_dict:set("pricing:ts", tostring(ngx.time()), STALE_SECONDS)`. |
| 8 | Release lock (`shared_dict:delete(LOCK_KEY)`). |

Returns: `true` on success, `nil, err` on failure. All errors are logged via
`core.log.warn` (never `error`, never throw).

### 4.3 `M.get_pricing(model_id)`

Synchronous shared-dict lookup. No cosocket, no I/O, microseconds.

| Parameter | Type | Notes |
|-----------|------|-------|
| `model_id` | string | The canonical model name from the request body (e.g. `"glm-5.2"`, `"frank/GLM-5.2"`, `"GLM-5.2"`). |

Internally normalizes the key the same way §4.2 step 5 does. If the entry is
missing OR past `TTL_SECONDS` AND `pricing:ts` is older than `STALE_SECONDS`,
triggers a background refresh via `M.warmup()` and returns whatever is in the
cache (stale-if-error semantics, see §7).

Returns:
- `pricing_table, "fresh"` - entry exists and is within TTL.
- `pricing_table, "stale"` - entry exists but past TTL (still returned; refresh triggered).
- `nil, "miss"` - entry does not exist. Caller records `source = "unknown"`.

### 4.4 Pricing table shape

```lua
{
    input       = 1.1,       -- USD per 1e6 tokens
    output      = 3.851,
    cache_read  = 0.275,
    cache_write = 0,
    reasoning   = nil,       -- nil means "use output rate" (matches opencode getUsage)
    fetched_at  = 1783400000 -- unix seconds, for staleness checks
}
```

`reasoning` is `nil` for any model where `models.dev` does not publish a
separate `reasoning` price. opencode charges reasoning at the output rate in
that case (`session.ts:402`); `compute_cost` does the same (§5.2).

### 4.5 `M.compute_cost(tokens, price)`

Pure function, no I/O. Mirrors opencode `Session.getUsage` exactly.

| Parameter | Type | Notes |
|-----------|------|-------|
| `tokens` | `{pt, ct, cached, reasoning}` | The four numbers returned by `sse_lib.extract_tokens`. |
| `price` | pricing table from `M.get_pricing` | See §4.4. |

Returns: `number` (Float64-compatible, never `nil`).

### 4.6 `M.resolve_cost(sse_cost, tokens, model_id)`

The single entry point `sse-usage.log` calls. Encapsulates the two-pathway
branch and returns both the cost and the source label, so callers cannot
mis-pair them.

```lua
function M.resolve_cost(sse_cost, tokens, model_id)
    if sse_cost and sse_cost > 0 then
        return sse_cost, M.SOURCE_UPSTREAM          -- Pathway A
    end
    local price = M.get_pricing(model_id)
    if not price then
        return 0, M.SOURCE_UNKNOWN                  -- Pathway B, no pricing
    end
    return M.compute_cost(tokens, price), M.SOURCE_COMPUTED   -- Pathway B, computed
end
```

Returns: `(cost: number, source: string)`. Always two values. Source is one of
the three module constants. The caller writes them verbatim into ClickHouse.

---

## 5. Cost Computation Math

### 5.1 Token decomposition (already done by `sse_usage_lib.extract_tokens`)

```
pt         = usage.prompt_tokens              -- includes cached
ct         = usage.completion_tokens          -- includes reasoning
cached     = usage.prompt_tokens_details.cached_tokens
reasoning  = usage.reasoning_tokens (top-level) or completion_tokens_details.reasoning_tokens
```

`cached ⊂ pt`; `reasoning ⊂ ct`. opencode's `getUsage` subtracts both
(`session.ts:366`, `session.ts:373`). We do the same:

```
input_uncached = pt - cached
output_non_reasoning = ct - reasoning
```

### 5.2 Formula (mirrors `session.ts:391-403`)

```
cost =  input_uncached       * price.input                       / 1e6
      + output_non_reasoning * price.output                      / 1e6
      + cached               * (price.cache_read  or 0)          / 1e6
      + 0                    * (price.cache_write or 0)          / 1e6   ← dead code, see §18.6
      + reasoning            * (price.reasoning or price.output) / 1e6
```

**`reasoning or price.output`** - `nil`-coalesce: if `price.reasoning` is nil
(models.dev does not publish a separate reasoning price), use `price.output`,
matching opencode's `// charge reasoning tokens at the same rate as output
tokens` comment.

**`0 * cache_write`** - this term is always zero because `sse_usage_lib` does
not extract a `cache_write` token count (the upstream doesn't report it).
opencode's formula includes `tokens.cache.write * costInfo.cache.write`, but
we have no `cache_write` token count to multiply. The `0 *` is a placeholder
that should be removed or wired up. See §18.6.

### 5.3 Worked example - LIVE VERIFIED (glm-5.2, 2026-07-07)

Live test sent `model: glm-5.2`, `stream: true`, `max_tokens: 50` via the
`/opencode/v1/chat/completions` route. ClickHouse row:

```
cost = 0.0002324, cost_source = 'computed'
prompt_tokens = 17, completion_tokens = 50, cached_tokens = 10, reasoning_tokens = 0
```

**Multiple providers publish `glm-5.2` in models.dev** - the `normalize_key`
function strips the provider prefix, so `alibaba-cn/glm-5.2`,
`vercel/zai/glm-5.2`, `huggingface/zai-org/GLM-5.2`, `novita-ai/zai-org/glm-5.2`,
and `alibaba-token-plan-cn/glm-5.2` all normalize to key `glm-5.2`.
Last-write-wins in the shared dict (see §14 Q5, §18.3). The live test resolved
to the `vercel/zai` (or `novita-ai`) pricing entry (both have identical rates):

```
price = {input=1.4, output=4.4, cache_read=0.26}   (vercel/zai or novita-ai, last-write-wins)
tokens = {pt=17, ct=50, cached=10, reasoning=0}

input_uncached       = 17 - 10 = 7
output_non_reasoning = 50 - 0  = 50

cost = 7  * 1.4  / 1e6  = 0.0000098
     + 50 * 4.4  / 1e6  = 0.0002200
     + 10 * 0.26 / 1e6  = 0.0000026
     + 0  * 0    / 1e6  = 0
     + 0  * 4.4  / 1e6  = 0     (reasoning=0 so term is 0 anyway)
                          = 0.0002324  ← matches ClickHouse row exactly
```

**NOTE:** If `alibaba-cn/glm-5.2` had won the last-write race (input=1.1,
output=3.851, cache_read=0.275), the cost would have been `0.000203` - a
14% difference. The non-deterministic provider collision is a known bug
(§18.3). The key takeaway: the computation formula is correct; the pricing
source is non-deterministic when multiple providers publish the same model
name with different rates.

### 5.4 Float precision

LuaJIT numbers are doubles (Float64). ClickHouse `cost` column is `Float64`.
No Decimal type is used. opencode uses `decimal.js` for client-side display
but stores `Schema.Finite` (number) in the database; we match that contract.
Rounding to cent precision is a **dashboard display** concern (Grafana
`decimals: 2`), not a storage concern.

---

## 6. Integration Points

### 6.1 `conf/config.yaml` - shared dict and init wiring

Add a new shared dict for pricing cache (alongside the existing `redact_state`
and `key_cache`):

```yaml
nginx_config:
  http:
    custom_lua_shared_dict:
      redact_state: 1m
      key_cache: 5m
      gateway-cache: 2m            # NEW - pricing table, ~1KB per model, ~200 models = 200KB
```

2MB is generous; the actual working set is ~200KB even with all of models.dev
cached. APISIX allocates this once per worker pool, shared across workers.

The module's `warmup()` is called from the `sse-usage` plugin's `init()`
hook (see §6.3). **APISIX does NOT call `plugin.init_worker()`** - the
plugin lifecycle (`apisix/plugin.lua:263-264`) invokes `plugin.init()` once
per worker during the plugin-load phase (which itself runs inside
`init_worker_by_lua*`):

```lua
-- apisix/plugin.lua:263
if plugin.init then
    plugin.init()
end
```

`plugin.init()` receives **no arguments** (no `conf`, no `ctx`) - the
per-route plugin configuration is not available at load time. The warmup
therefore uses the module's hardcoded default URL
(`https://models.dev/api.json`). The per-route `models_dev_url` schema field
(§10.1) is **not usable at init time**; it is reserved for a future v1.1
mechanism where the first request writes the configured URL into the shared
dict and a timer picks it up. For v1, the default URL is correct and
production-safe.

**Cosocket limitation:** `init_worker_by_lua*` (and therefore `plugin.init()`)
runs in a context where OpenResty cosockets are **not available** - calling
`resty.http` directly in `plugin.init()` will fail with
`API disabled in the context of init_worker_by_lua*`. The standard OpenResty
workaround is `ngx.timer.at(0, handler)`: the timer callback runs in a
cosocket-capable context, so `resty.http` works there. `warmup()` uses
exactly this pattern (§4.1). This is not a preference - it is a hard
OpenResty constraint. See
<https://github.com/openresty/lua-nginx-module#ngxtimerat>.

```lua
-- in sse-usage.lua
function plugin.init()
    local cost_calc = require("apisix.plugins.cost_calc")
    cost_calc.warmup()
end
```

### 6.2 `conf/apisix.yaml` - no route changes

`cost_calc` is a library, not a route-bound plugin. The `sse-usage` plugin
already appears on both routes (`relay-opencode`, `relay-opencode-federated`).
No new plugin entries in `apisix.yaml`.

### 6.3 `plugins/custom/sse-usage.lua` - modifications

Three changes:

```lua
-- (1) at top of file, after the existing requires
local cost_calc = require("apisix.plugins.cost_calc")

-- (2) new init hook (APISIX calls plugin.init() at plugin.lua:263, NOT init_worker)
function plugin.init()
    cost_calc.warmup()
end

-- (3) in plugin.log, replacing the current `local cost = tonumber(ctx.sse_cost) or 0`:
local pt, ct, tt, cached, reasoning = sse_lib.extract_tokens(ctx.sse_usage)
local model = ctx.sse_model or ""
local sse_cost = tonumber(ctx.sse_cost) or 0
local req_model = ctx.sse_req_model or model    -- captured in access phase from request body
local final_cost, cost_source = cost_calc.resolve_cost(sse_cost, {pt=pt, ct=ct, cached=cached, reasoning=reasoning}, req_model)
```

The `entry` JSON object gains two fields:

```lua
local entry = cjson.encode({
    -- ... existing fields ...
    cost = final_cost,
    cost_source = cost_source,    -- "upstream" | "computed" | "unknown"
})
```

`ctx.sse_req_model` is captured once in the `access` phase by reading the
request body's `model` field (before the upstream proxy consumes the body).
It is the **canonical** model name the client sent (e.g. `"glm-5.2"`),
distinct from `ctx.sse_model` which is the **upstream-echoed** name
(e.g. `"frank/GLM-5.2"`). Pricing lookup uses the canonical name; the
`usage_log.model` column continues to store the upstream echo (unchanged).

**Body capture approach:** APISIX's `access` phase can read the request body
via `core.request.get_body()` before proxying. The existing sse-usage.lua
already reads the body in the `log` phase as a fallback for `model` when the
SSE stream provided none (sse-usage.lua:135-143). For `req_model`, we capture
it in `access` (or reuse the log-phase body read) and store it on `ctx` so it
is available regardless of whether the stream completed. If the body is empty
or unparseable, `req_model` falls back to the upstream-echoed `ctx.sse_model`,
which is then normalized by `get_pricing` (§4.3).

---

## 7. Cache Strategy and Failure Modes

### 7.1 Freshness ladder

| State | `pricing:ts` age | `pricing:<model>` age | Behavior |
|-------|------------------|------------------------|----------|
| Fresh | < 1h | < 1h | Served directly. No refresh. |
| Stale | > 1h | < 24h | Served. Background `warmup()` triggered on next `get_pricing` call. |
| Expired | > 24h (or missing) | > 24h (or missing) | `get_pricing` returns `nil, "miss"`. Caller records `source = "unknown"`, `cost = 0`. Background `warmup()` triggered. |
| Fetch in flight | n/a | n/a | `pricing:lock` held. Other workers skip spawn. Stale cache still served. |

### 7.2 Fetch failure (network down, 5xx, JSON decode error)

`fetch_and_cache` **never overwrites or deletes existing entries on failure**.
It logs `core.log.warn("cost_calc: models.dev fetch failed: ", err)` and
returns. Existing cache entries remain queryable until they cross
`STALE_SECONDS` (24h). This is "stale-if-error" - the same pattern opencode
uses (`models-dev.ts:215-231` ignores refresh errors).

If the cache is empty AND the fetch fails, every request for a model gets
`source = "unknown"`, `cost = 0`. This is **explicit and labeled**, not a
silent zero. The dashboard's `cost_source` breakdown will show 100% unknown
and the operator can investigate (curl models.dev from the APISIX container,
check DNS, etc.).

### 7.3 Partial pricing (some models in models.dev, some not)

Each model is keyed independently. A request for `glm-5.2` (in models.dev)
gets `source = "computed"` with a real cost. A request for
`some-custom-model` (not in models.dev) gets `source = "unknown"` with
`cost = 0`. There is no global "pricing is available" flag.

### 7.4 Shared dict eviction

`ngx.shared.dict` has a fixed size (2MB here). If the dict fills, oldest
entries are evicted. With ~200 models at ~1KB each, this never happens in
practice. If it does, `get_pricing` returns `nil, "miss"` for evicted keys
and the request falls to `source = "unknown"`. No crash, no incorrect data.

### 7.5 Race on concurrent `warmup`

The `pricing:lock` shared-dict key (set with `NX` + 30s expiry) ensures only
one worker at a time fetches. Other workers see the lock held and skip
spawning their own fetch. If the lock-holding worker crashes mid-fetch, the
30s TTL auto-expires the lock and the next `warmup` call retries.

---

## 8. Storage Schema

### 8.1 `conf/clickhouse-init.sql` - new column

```sql
ALTER TABLE llm_gateway.usage_log
    ADD COLUMN IF NOT EXISTS cost_source Enum8('upstream' = 0, 'computed' = 1, 'unknown' = 2)
    DEFAULT 2;
```

Idempotent (`IF NOT EXISTS`), same pattern as the existing `cost` column ALTER.
Default `2` (`unknown`) so existing rows (pre-migration) are explicitly marked
as unknown-source rather than silently zero.

The `CREATE TABLE` block also gets the column inline so fresh deployments
don't need the ALTER:

```sql
CREATE TABLE IF NOT EXISTS llm_gateway.usage_log (
    -- ... existing columns ...
    cost Float64 DEFAULT 0,
    cost_source Enum8('upstream' = 0, 'computed' = 1, 'unknown' = 2) DEFAULT 2,
    -- ...
) ENGINE = MergeTree ...
```

### 8.2 ClickHouse enum mapping for INSERT

The `sse-usage` INSERT body sends `cost_source` as a string
(`"upstream"`, `"computed"`, `"unknown"`). ClickHouse's `JSONEachRow` format
accepts the enum value name as a string and casts it automatically. No
numeric mapping needed in Lua.

### 8.3 Backfill

No backfill is performed. Historical rows keep `cost_source = 2` (the
column DEFAULT). New rows get the correct source. The dashboard can filter
`cost_source IN ('upstream','computed')` if it wants only authoritative cost
data, or include all rows for a raw total.

---

## 9. Dashboard Integration

### 9.1 p3 (Token Usage card) - new "Cost Source" tile

Add a 7th field override to p3:

| Field | Display name | Unit | Color |
|-------|--------------|------|-------|
| `sumIf(cost, cost_source='upstream')` | `UPSTREAM $` | currencyUSD | gold (`#ffe066`) |
| `sumIf(cost, cost_source='computed')` | `COMPUTED $` | currencyUSD | teal (`#70c1b3`) |
| `sumIf(cost, cost_source='unknown')` | `UNKNOWN $` | currencyUSD | coral (`#f25f5c`) |

The existing `TOTAL COST` tile remains. The three new tiles let the operator
see at a glance whether the gateway is using upstream cost (gold), computed
cost (teal - the expected dominant state for GLM-5.2), or unknown (coral -
investigation needed).

### 9.2 New panel p16 - Cost by Source (stacked timeseries)

| Property | Value |
|----------|-------|
| `id` | 16 |
| `title` | `Cost by Source (upstream / computed / unknown) $` |
| `type` | `timeseries` |
| `gridPos` | `y=52, x=0, w=24, h=8` (full width, below p12) |
| `datasource` | ClickHouse |
| `query` | `SELECT sum(cost), cost_source, toStartOfInterval(timestamp, INTERVAL 1 minute) AS t FROM llm_gateway.usage_log WHERE $__timeFilter(timestamp) AND api_key=$__conditionalAll{api_key_id, "$api_key"} AND model=$__conditionalAll{model, "$model"} GROUP BY cost_source, t ORDER BY t` |
| `stack` | `percent` (shows relative mix) |
| `colors` | gold / teal / coral (matching the p3 tiles) |

The panel answers "is my cost data authoritative?" - a flat coral line means
pricing fetch is broken; a teal-dominated line means Pathway B is healthy; a
gold spike means a provider started reporting cost upstream.

### 9.3 p15 (Cost Over Time by Model) - unchanged

Already sums `cost` across all sources. With Pathway B now producing non-zero
values for GLM-5.2, this panel populates correctly.

---

## 10. Configuration Surface

### 10.1 `sse-usage` plugin schema - unchanged in v1

```lua
plugin.schema = {
    type = "object",
    properties = {
        clickhouse_addr = { type = "string", default = "http://clickhouse:8123" },
    },
}
```

**No `models_dev_url` field is added in v1.** `plugin.init()` receives no
`conf` argument (APISIX calls `plugin.init()` with zero args at
`plugin.lua:263`), so a per-route `models_dev_url` would be invisible to the
warmup call. Adding a schema field that cannot be read at the only point it
matters would be misleading. The models.dev URL is a module-level constant
(`https://models.dev/api.json`) - correct for production and overridable only
by editing the module source. A v1.1 mechanism (first request writes
`conf.models_dev_url` into the shared dict; a timer picks it up) can restore
per-deployment configurability without code changes if needed.

### 10.2 No new env vars

Pricing data is public. No auth token, no API key, no secret. The only
configuration is the URL, which is a module-level constant in v1.

---

## 11. Test Plan

### 11.1 `tests/config/test_cost_calc.sh` (new file)

Static config tests, run by the existing CI harness (`Makefile` target
`test-config`):

| # | Test | Asserts |
|---|------|---------|
| 1 | `plugins/custom/cost_calc.lua` exists | file present |
| 2 | Module returns a table | `require` returns table type |
| 3 | Exposes `warmup`, `fetch_and_cache`, `get_pricing`, `compute_cost`, `resolve_cost` | all are functions |
| 4 | Exposes `SOURCE_UPSTREAM`, `SOURCE_COMPUTED`, `SOURCE_UNKNOWN` constants | string values `"upstream"`, `"computed"`, `"unknown"` |
| 5 | `compute_cost({pt=1e6, ct=0, cached=0, reasoning=0}, {input=1, output=2})` returns `1.0` | input-only math |
| 6 | `compute_cost({pt=0, ct=1e6, cached=0, reasoning=0}, {input=1, output=2})` returns `2.0` | output-only math |
| 7 | `compute_cost({pt=1e6, ct=0, cached=5e5, reasoning=0}, {input=1, output=2, cache_read=0.1})` returns `0.55` | cache_read math: 5e5*1/1e6 + 5e5*0.1/1e6 = 0.5 + 0.05 |
| 8 | `compute_cost({pt=0, ct=1e6, cached=0, reasoning=3e5}, {input=1, output=2, reasoning=nil})` returns `2.0` | reasoning falls back to output rate: 7e5*2/1e6 + 3e5*2/1e6 = 1.4 + 0.6 |
| 9 | `compute_cost({pt=0, ct=1e6, cached=0, reasoning=3e5}, {input=1, output=2, reasoning=4})` returns `2.6` | reasoning uses its own rate: 7e5*2/1e6 + 3e5*4/1e6 = 1.4 + 1.2 |
| 10 | `resolve_cost(0.5, {pt=1e6, ct=0, cached=0, reasoning=0}, "glm-5.2")` returns `(0.5, "upstream")` | Pathway A - sse_cost > 0 wins |
| 11 | `resolve_cost(0, {pt=1e6, ct=0, cached=0, reasoning=0}, "nonexistent-model")` returns `(0, "unknown")` | Pathway B miss - uses a model guaranteed not in the (test) cache |
| 12 | `resolve_cost` always returns exactly 2 values | no nil-leak |

Tests 5-12 run in plain LuaJIT with **zero dependency injection** (see
§11.3). `compute_cost` is pure Lua math. `resolve_cost`'s upstream branch
returns before any cache lookup; its unknown branch hits the real
`get_pricing` miss path (no `ngx.shared.dict` in plain LuaJIT →
`get_dict()` returns nil → miss). No globals are injected, no modules are
preloaded - the module's lazy requires and `ngx` guard make this possible.

### 11.2 Augmented existing tests

| File | New assertions |
|------|----------------|
| `test_clickhouse_sql.sh` | `cost_source Enum8(...)` column present in CREATE TABLE; idempotent ALTER block present; enum values are `'upstream'=0, 'computed'=1, 'unknown'=2` |
| `test_config_yaml.sh` | `gateway-cache` shared dict present in `custom_lua_shared_dict`; size is `2m` |
| `test_apisix_yaml.sh` | unchanged (no route changes) |
| `test_grafana_provisioning.sh` | p3 has 9 field overrides (was 6 - adds upstream/computed/unknown tiles); p16 exists with title `Cost by Source`, type `timeseries`, query references `cost_source`; p16 gridPos is `y=52, x=0, w=24, h=8` |

### 11.3 Test harness - lazy requires, zero dependency injection

`resty.http` **is available** in the APISIX container at
`/usr/local/apisix/deps/share/lua/5.1/resty/http.lua` - it is used by
built-in plugins (`forward-auth`, `ext-plugin-post-resp`) and by our own
`sse-usage.lua` (verified live for ClickHouse inserts). However, it is a
**cosocket library** and only works inside an Nginx worker context. Running
`luajit -e "require('resty.http')"` from the CLI fails with
`module 'resty.http' not found` because the cosocket runtime is not
initialized outside Nginx. **Do not use the CLI test as a presence check.**

**Solution (implemented):** `cost_calc.lua` uses **lazy requires** -
`apisix.core`, `cjson.safe`, and `resty.http` are `require()`-d *inside*
the functions that use them (`warmup`, `fetch_and_cache`, `get_pricing`),
not at module top level. The `ngx` global is guarded in `get_dict()`
(`if not ngx or not ngx.shared then return nil end`). This means:

- `compute_cost(tokens, price)` - pure Lua math, zero external
  dependencies. Runs in plain LuaJIT with no nginx runtime.
- `resolve_cost(sse_cost, tokens, model_id)` - the upstream branch
  (`sse_cost > 0`) returns before touching `get_pricing`, so it runs
  with zero dependencies. The unknown branch calls `get_pricing`, which
  calls `get_dict()`, which returns `nil` (no `ngx` global in plain
  LuaJIT) → `get_pricing` returns `nil, "miss"` → `resolve_cost` returns
  `(0, "unknown")`. This is the **real** Pathway-B-miss code path, not a
  fake one - the cache genuinely has no `ngx.shared.dict` to look up.
- `warmup` / `fetch_and_cache` / `get_pricing` (fresh/stale branches) -
  these require the nginx runtime and are integration-tested via the
  live verification in §11.4.

All 21 assertions in `test_cost_calc.sh` run inside the APISIX
container's `luajit` (the only place LuaJIT is installed on this host)
with **zero dependency injection** - no injected globals, no preloaded
modules, no nginx worker runtime. The module loads and the pure
functions execute against their real logic.

### 11.4 Live verification - COMPLETED 2026-07-07

All three pathways verified live against the running gateway:

| Step | Model | Expected | Actual ClickHouse row | Status |
|------|-------|----------|----------------------|--------|
| 1-4 | `glm-5.2` | `cost_source='computed'`, `cost>0` | `cost=0.0002324, cost_source='computed', pt=17, ct=50, cached=10, reasoning=0` | **PASS** - Pathway B, math matches §5.3 |
| 5-6 | `glm-5.1` | `cost_source='upstream'`, `cost>0` | `cost=0.0002438, cost_source='upstream', pt=17, ct=50, cached=0, reasoning=0` | **PASS** - Pathway A, upstream emitted non-zero cost in an earlier SSE chunk |
| 7-8 | `some-fake-model-xyz` | `cost_source='unknown'`, `cost=0` | Upstream returned `ModelError` JSON (not SSE) → no usage_log row inserted | **N/A** - upstream rejects unknown models before usage is generated. `unknown` pathway verified via (a) unit test 11 (`resolve_cost(0, ..., "nonexistent")` → `(0, "unknown")`) and (b) historical rows in ClickHouse showing `cost_source='unknown'` (DEFAULT 2 from ALTER). |
| 9 | Grafana p3 + p16 screenshot | Tiles + panel visible | **NOT DONE** - dashboard v27 JSON is in the repo file but NOT deployed to the running Grafana container. The Grafana dashboard volume is mounted read-only (`:ro` in docker-compose.yml line 98); `podman cp` fails with "read-only file system". Container restart is needed to pick up the mounted file. See §18.5. |

**Shared dict verification:** Could not inspect `ngx.shared["gateway-cache"]`
contents directly - `resty -e` and `luajit -e` run outside the nginx worker
context, so `ngx.shared` returns nil. However, the fact that `cost_source=
'computed'` and `cost > 0` for the glm-5.2 request proves the pricing cache
was populated and the lookup succeeded. The computed value (0.0002324)
matches the `vercel/zai` pricing entry exactly, confirming the fetch, cache,
normalize, and compute pipeline all worked end-to-end.

---

## 12. Failure Modes Summary

| Scenario | Behavior | Observability |
|----------|----------|---------------|
| models.dev unreachable (cold cache) | `cost = 0`, `cost_source = 'unknown'` | Dashboard p3 UNKNOWN tile non-zero; APISIX error log has `cost_calc: models.dev fetch failed` |
| models.dev unreachable (warm cache, < 24h old) | `cost = computed`, `cost_source = 'computed'` (stale pricing) | No user-visible signal; log has fetch-failure warnings |
| models.dev returns malformed JSON | Same as unreachable | Log has decode error |
| Model not in models.dev | `cost = 0`, `cost_source = 'unknown'` | p3 UNKNOWN tile; expected for genuinely unlisted models |
| Shared dict full | Evicted keys return miss → `cost_source = 'unknown'` | Log has eviction warnings from ngx.shared.dict |
| `sse-usage` log phase crashes after `resolve_cost` | Row not inserted (existing behavior) | Existing APISIX error log |
| `cost_calc` module fails to load (syntax error) | `sse-usage` plugin fails to load → APISIX worker won't start | Container logs show Lua require error; CI catches via `luajit -bl` syntax check in `test_cost_calc.sh` |

---

## 13. Out of Scope (v1)

- **Context-over-200k tiered pricing**: opencode's `getUsage` selects a tier
  when `inputTokens > 200_000` (session.ts:382-388). v1 uses the base tier
  only. Adding tier selection is a v1.1 change: `get_pricing` would return
  the full tier list and `compute_cost` would select based on `pt`.
- **Copilot `totalNanoAiu` special case** (session.ts:389-393): Copilot
  reports cost in nano-AIU units. v1 ignores this - Pathway A handles it
  (upstream cost is used as-is) and Pathway B never applies (Copilot models
  always report upstream cost).
- **Per-key custom pricing overrides**: an operator may want to override
  models.dev pricing for a specific key (negotiated rates). v1 has no
  mechanism; a v2 could add a `pricing_overrides` table in ClickHouse and
  have `get_pricing` check it first.
- **Backfill**: historical rows keep `cost_source = 'unknown'`. A v1.1
  backfill script could recompute historical costs from stored tokens ×
  current pricing, but this is a separate concern.

---

## 14. Open Questions

| # | Question | Default for v1 | Revisit at |
|---|----------|----------------|------------|
| 1 | Should `cost_source = 'unknown'` rows be excluded from the p15 "Cost Over Time" panel? | No - show all sources in p15; p16 shows the breakdown | After 1 week of production data |
| 2 | Should the dashboard show "stale pricing" warning when `pricing:ts` > 1h? | No - operator checks APISIX logs. A dedicated "Pricing Freshness" stat panel is a v1.1 addition if needed. | v1.1 |
| 3 | Is 1h TTL too aggressive? models.dev updates rarely. | 1h matches opencode's effective refresh cadence (60min). Can bump to 6h if fetch load is a concern. | After monitoring fetch frequency |
| 4 | Should `cost_calc` expose Prometheus metrics (cache hits/misses, fetch latency)? | Not in v1. The shared dict is observable via APISIX's built-in `/apisix/prometheus/metrics` if we export a custom metric. | v1.1 |
| 5 | What if two models normalize to the same key (e.g. `vercel/zai/glm-5.2` and `alibaba-cn/glm-5.2`)? | Last-write-wins in the shared dict. **LIVE VERIFIED 2026-07-07:** 5 providers publish `glm-5.2` with different rates. The live test resolved to `vercel/zai` pricing (input=1.4) instead of `alibaba-cn` (input=1.1) - a 14% overcharge. The non-deterministic iteration order of `pairs()` means the winning provider varies between worker restarts. **This is a real correctness bug, not a theoretical concern.** Fix: include the full `provider_id/model_id` as the shared-dict key, or select the cheapest provider (matches opencode's behavior of using the first provider it finds). See §18.3. | **v1.1 - must fix before production** |

---

## 15. References

| Source | Location | Used for |
|--------|----------|----------|
| opencode `Session.getUsage` | `packages/opencode/src/session/session.ts:338-404` | Cost computation formula (§5.2) |
| opencode `ModelsDev` service | `packages/core/src/models-dev.ts:123-240` | Fetch/cache/TTL pattern (§4.2, §7) |
| opencode `models-dev` plugin | `packages/core/src/plugin/models-dev.ts:13-50` | Pricing table shape (§4.4) |
| models.dev API | `https://models.dev/api.json` | Source of pricing data |
| `sse_usage_lib.extract_tokens` | `plugins/custom/sse_usage_lib.lua:70-86` | Token decomposition (§5.1) |
| `sse-usage` plugin | `plugins/custom/sse-usage.lua` | Integration point (§6.3) |
| APISIX shared dict docs | `https://apisix.apache.org/docs/apisix/terminology/shared-dict/` | Cache primitive (§2) |
| APISIX `ngx.timer.at` | `https://github.com/openresty/lua-nginx-module#ngxtimerat` | Async fetch (§4.2) |
| `PLUGIN-FOUNDATION.md` | `docs/PLUGIN-FOUNDATION.md` | Inherited contracts (plugin structure, phases) |

---

## 16. Implementation Checklist

- [x] `plugins/custom/cost_calc.lua` - module with §4 API (deployed to `/usr/local/apisix/apisix/plugins/cost_calc.lua` via `podman cp`)
- [x] `plugins/custom/sse-usage.lua` - added `require("apisix.plugins.cost_calc")`, `function plugin.init()` calling `cost_calc.warmup()`, `resolve_cost()` call in log phase, `cost_source` in INSERT JSON
- [x] `plugins/custom/sse-usage.lua` - capture `ctx.sse_req_model` from request body (`core.request.get_body()` in access phase)
- [x] `conf/config.yaml` - added `gateway-cache: 2m` to `nginx_config.http.custom_lua_shared_dict`
- [x] `conf/clickhouse-init.sql` - added `cost_source Enum8(...)` to CREATE TABLE + idempotent ALTER; live ALTER applied to running ClickHouse
- [x] `conf/grafana/dashboards/gateway-cost-usage.json` - p3 has 9 targets/9 overrides (3 new source tiles); p16 panel added (v27). Original `gateway-overview.json` later split into 3 dashboards (cost-usage, ops-health, cost-leaderboard); p3 now lives in cost-usage, p16 was removed during the split.
- [x] `tests/config/test_cost_calc.sh` - 21 tests (file, module table, 5 functions, 3 constants, 5 compute_cost math, 2 resolve_cost, 2 return-value-count), ALL PASS
- [x] `tests/config/test_clickhouse_sql.sh` - added `cost_source` column assertions (28 tests, ALL PASS)
- [x] `tests/config/test_config_yaml.sh` - added `gateway-cache` dict assertion (23 tests, ALL PASS)
- [x] `tests/config/test_grafana_provisioning.sh` - added p3 9-override + p16 assertions (59 tests, ALL PASS)
- [x] Deploy: `podman cp` the two Lua files to `/usr/local/apisix/apisix/plugins/`; `config.yaml` was already volume-mounted (the cp was redundant); restarted APISIX; verified `plugin.init()` fired (cost_source='computed' in ClickHouse proves pricing cache populated)
- [x] Live verification per §11.4 - glm-5.2 → computed (PASS), glm-5.1 → upstream (PASS), fake model → N/A (upstream rejects), unknown pathway verified via unit test + historical rows
- [ ] **NOT DONE:** Playwright screenshot of p3 + p16 - dashboard v27 JSON is in the repo but NOT deployed to running Grafana (read-only volume mount, see §18.5)
- [ ] **NOT DONE:** Fix deployment infrastructure (Dockerfile missing COPY for `cost_calc.lua` and `key-meta.lua`; no volume mount for `plugins/custom/`; see §18.1, §18.2)
- [x] Run full test suite: 237 tests across 9 files, 0 failures

---

## 17. Verified APISIX Runtime Facts (Appendix)

All facts below were verified against the running `docker_apisix_1` container
(APISIX 3.17.0) and the official APISIX/OpenResty documentation on
2026-07-07. They supersede any contradictory assumption in earlier drafts.

### 17.1 `resty.http` availability

| Check | Result |
|-------|--------|
| File location | `/usr/local/apisix/deps/share/lua/5.1/resty/http.lua` |
| Used by built-in plugins | `forward-auth.lua`, `ext-plugin-post-resp.lua` (both `require("resty.http")`) |
| Used by our plugins | `sse-usage.lua:3` - verified live for ClickHouse INSERT (200 status) |
| CLI `luajit -e "require('resty.http')"` | **FAILS** - cosocket libs need the Nginx worker runtime; this is a false negative, NOT a real absence |
| Alternative present | `lua-resty-luasocket` at `/usr/local/apisix/deps/lib/luarocks/rocks-5.1/lua-resty-luasocket/1.1.2-1/` (`resty.luasocket.http`) - not needed; `resty.http` works |

**Conclusion:** Use `require("resty.http")` in `cost_calc.lua`. It works in
any Nginx worker phase (`access`, `rewrite`, `log`) and inside
`ngx.timer.at` callbacks. It does NOT work in `init_worker_by_lua*` directly
(cosocket limitation - see §17.4) or from the `luajit` CLI.

### 17.2 Custom plugin deployment path

| Aspect | Value |
|--------|-------|
| Deployed plugins directory | `/usr/local/apisix/apisix/plugins/` (flat - NO `custom/` subdir) |
| Existing custom plugins present | `sse-usage.lua`, `sse_usage_lib.lua`, `key-meta.lua`, `key-resolver.lua` (all flat in plugins dir) |
| Require path | `require("apisix.plugins.cost_calc")` resolves to `/usr/local/apisix/apisix/plugins/cost_calc.lua` |
| Official alternative | `extra_lua_path` in `config.yaml` pointing at a separate source tree with `apisix/plugins/` subdirectory (see APISIX plugin-develop docs) |
| Our deployment method | `podman cp plugins/custom/cost_calc.lua docker_apisix_1:/usr/local/apisix/apisix/plugins/cost_calc.lua` (must STOP container first, then START) - **WARNING: manual, not reproducible. See §18.1, §18.2.** |

**Conclusion:** The `plugins/custom/` path in this repo is source
organization only. Deployment flattens into the plugins directory. The module
is NOT registered in the `plugins:` list in `config.yaml` (it is a library,
not a plugin - see §18.7) - only `sse-usage` is registered, and it requires
`cost_calc` at load time.

**WARNING:** The current deployment method (`podman cp`) is not captured in
the Dockerfile or docker-compose.yml. See §18.1 (Dockerfile missing COPY)
and §18.2 (no volume mount for `plugins/custom/`). An image rebuild or
container recreation will lose `cost_calc.lua` and `key-meta.lua`.

### 17.3 Plugin lifecycle: `init()` not `init_worker()`

| Aspect | Fact |
|--------|------|
| APISIX source | `apisix/plugin.lua:263-264`: `if plugin.init then plugin.init() end` |
| Called from | `_M.load()` inside `_M.init_worker()` (the APISIX module's init_worker, NOT per-plugin) |
| When | Once per worker, during `init_worker_by_lua*` |
| Args | **Zero** - `plugin.init()` receives no `conf`, no `ctx` |
| `plugin.init_worker()` | **NOT called by APISIX** for regular plugins. Only internal APISIX modules (`router`, `consumer`, `discovery.*`, `ext-plugin/init`) have `init_worker` methods, invoked by explicit APISIX-internal dispatch, not by the generic plugin loader. |
| Per-worker cosockets | **Unavailable** in `init_worker_by_lua*` → `plugin.init()` cannot call `resty.http` directly |

**Conclusion:** Use `function plugin.init() cost_calc.warmup() end` (NOT
`plugin.init_worker()`). `warmup()` spawns `ngx.timer.at(0, fetch_and_cache)`
which runs in a cosocket-capable context.

### 17.4 `ngx.timer.at` and the cosocket limitation

| Context | Cosockets? | `ngx.timer.at`? |
|---------|-----------|-----------------|
| `init_by_lua*` (master, pre-fork) | No | No |
| `init_worker_by_lua*` (per worker) | **No** | **Yes** |
| `access/rewrite/header_filter/body_filter/log_by_lua*` | Yes | Yes |
| `ngx.timer.at` callback | **Yes** | n/a |

Source: OpenResty `lua-nginx-module` README -
<https://github.com/openresty/lua-nginx-module#ngxtimerat> lists
`init_worker_by_lua*` as a valid context for `ngx.timer.at`, and
<https://github.com/openresty/lua-nginx-module#ngxsockettcp> confirms
cosockets are disabled in `init_by_lua*` and `init_worker_by_lua*`.

**Conclusion:** The ONLY way to make an HTTP call during worker startup is
`ngx.timer.at(0, handler)` where `handler` uses `resty.http`. This is the
pattern `cost_calc.warmup()` uses. It is a hard OpenResty constraint, not a
design preference.

### 17.5 `custom_lua_shared_dict` generates real `lua_shared_dict`

| Check | Result |
|-------|--------|
| `conf/config.yaml` entry | `nginx_config.http.custom_lua_shared_dict: {redact_state: 1m, key_cache: 5m, gateway-cache: 2m}` |
| Generated `nginx.conf` | `lua_shared_dict redact_state 1m;`, `lua_shared_dict key_cache 5m;`, `lua_shared_dict gateway-cache 2m;` - all confirmed present |
| Template source | `apisix/cli/ngx_tpl.lua:293`: `lua_shared_dict {*key*} {*size*};` iterates `http.lua_shared_dict` |
| APISIX doc reference | <https://apisix.apache.org/docs/apisix/customize-nginx-configuration/> - `custom_lua_shared_dict` is the structured helper; raw `http_configuration_snippet` with `lua_shared_dict` is the alternative |

**Conclusion:** Adding `gateway-cache: 2m` to `custom_lua_shared_dict`
produces `lua_shared_dict gateway-cache 2m;` in `nginx.conf`, accessible via
`ngx.shared["gateway-cache"]` in Lua. No `http_configuration_snippet` needed.

### 17.6 models.dev API shape (verified 2026-07-07)

| Provider | Model ID | Cost object |
|----------|----------|-------------|
| `alibaba-cn` | `glm-5.2` | `{input: 1.1, output: 3.851, cache_read: 0.275, cache_write: 0}` |
| `alibaba-cn` | `glm-5.1` | `{input: 0.87, output: 3.48, cache_read: 0.17}` |
| `alibaba-cn` | `glm-5` | `{input: 0.86, output: 3.15}` |
| `qiniu-ai` | `glm-4.5` | `null` (no cost published) |
| 71 models globally | various | have a separate `reasoning` cost field (e.g. `qwen-plus`: `{input: 0.115, output: 0.287, reasoning: 1.147}`) |

**Top-level structure:** `{<provider_id>: {models: {<model_id>: {id, name, cost: {...}, ...}}}}`.
The `cost` object keys are `input`, `output`, `cache_read`, `cache_write`,
and optionally `reasoning`. When `reasoning` is absent, opencode charges
reasoning tokens at the `output` rate (`session.ts:402`); `compute_cost`
does the same (§5.2).

**Conclusion:** `fetch_and_cache` iterates `data[provider].models[model]`,
extracts `cost` if present and non-null, normalizes the model id (lowercase,
strip `provider/` prefix), and writes `cjson.encode({input=..., output=...,
cache_read=..., cache_write=..., reasoning=...})` to the shared dict. The
`reasoning` field is `nil` (omitted) when not present, so `compute_cost`'s
`price.reasoning or price.output` nil-coalesce works correctly.

---

## 18. Known Deployment Gaps and Technical Debt

**Added 2026-07-07 after live verification. All 9 items FIXED 2026-07-07.**

These issues were discovered during the deployment and live-testing phase.
The core logic (cost computation, two-pathway resolution, shared-dict
caching) is verified correct. The issues below were deployment-infrastructure
and correctness-edge-case problems. All have been fixed.

### 18.1 Dockerfile.apisix missing COPY directives - FIXED

**Status:** FIXED - `cost_calc.lua` and `key-meta.lua` now have COPY directives.
**File:** `res/docker/Dockerfile.apisix`

The Dockerfile now COPYs all 7 custom plugins:
`key-resolver.lua`, `key-meta.lua`, `sse-usage.lua`, `sse_usage_lib.lua`,
`cost_calc.lua`, `redact.lua`, `redact_lib.lua`.

### 18.2 No volume mount for plugins - FIXED

**Status:** FIXED - all 7 plugin files are now volume-mounted `:ro` in
`docker-compose.yml` (individual flat file mounts, matching the deployment
path). Image rebuilds are no longer required for plugin changes.

### 18.3 Pricing key collision - FIXED

**Status:** FIXED - `fetch_and_cache` now collects all providers per model
key, sorts by input rate (cheapest first), and stores as a JSON array.
`get_pricing` decodes the array and picks the first (cheapest) entry.
Selection is deterministic regardless of `pairs()` iteration order.

### 18.4 `plugin.init()` error handling - FIXED

**Status:** FIXED - `plugin.init()` now checks the return value of
`cost_calc.warmup()` and logs a warning on failure:
```lua
function plugin.init()
    local ok, err = cost_calc.warmup()
    if not ok then
        core.log.warn("sse-usage: cost_calc.warmup() failed: ", err or "unknown")
    end
end
```

### 18.5 Dashboard not deployed - FIXED

**Status:** FIXED - Grafana container restarted (`podman restart gw-grafana`).
Dashboard v28 is live with 16 panels: table-based Token Usage by Category
(one row per category with tokens + cost columns), Cost by Source stat tiles,
and Cost by Source timeseries.

### 18.6 Dead code `0 * cache_write_rate` - FIXED

**Status:** FIXED - the `0 * cache_write_rate / 1e6` term and the unused
`cache_write_rate` variable have been removed from `compute_cost`.

### 18.7 `cost_calc` not in plugins list - FIXED

**Status:** FIXED - a comment in `config.yaml` now explains:
```yaml
# cost_calc is a library (require'd by sse-usage), not a route-bound plugin - not listed here.
plugins:
```

### 18.8 No end-to-end integration test - FIXED

**Status:** FIXED - `tests/integration/test_cost_e2e.sh` created. Sends a
curl request through the gateway, queries ClickHouse for the latest
`usage_log` row, and asserts `cost_source` is a valid enum value and
`cost > 0` for `computed`/`upstream` sources.

### 18.9 No ClickHouse migration script - FIXED

**Status:** FIXED - `conf/clickhouse-migration-cost-source.sql` created.
Idempotent `ALTER TABLE ... ADD COLUMN IF NOT EXISTS cost_source` for
existing deployments where `clickhouse-init.sql` was already run.

### 18.10 Free/trial provider filtering (2026-07-07)

**Status:** FIXED - providers with `input == 0 AND output == 0` are now
skipped during `fetch_and_cache`. The `alibaba-token-plan-cn` provider
publishes `glm-5.2` with all rates = 0 (a free/trial plan). The
cheapest-first sort from §18.3's fix was selecting it first (0 < 1.1),
causing all computed costs to be 0. The filter excludes such providers
before the sort, so only real paid pricing is considered.

**Verification:** E2E test (`tests/integration/test_cost_e2e.sh`) confirms
`cost_source=computed, cost=0.0001742` for `glm-5.2` after the fix.


