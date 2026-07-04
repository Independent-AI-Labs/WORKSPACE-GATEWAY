# Plugin Spec: Adaptive Multi-Provider Failover - Hybrid Proxy-Wasm + Lua

**Document ID:** AMI-PROP-LLMGW-PLUGIN-FAILOVER-v1.0
**Status:** Draft
**Date:** 2026-07-04
**Parent:** `PROPOSAL-LLM-GATEWAY-v2.md`; inherits `PLUGIN-FOUNDATION.md`
**Replaces:** Kong Enterprise `ai-proxy-advanced` plugin (`tier: ai_gateway_enterprise`)

This document specifies the multi-provider LLM routing component with weighted load
balancing, adaptive mid-flight failover on HTTP 429/5xx, per-target circuit breaker,
provider-specific format translation (OpenAI / Azure / Bedrock / vLLM), and
`stream_options.include_usage` enforcement for billing-grade token accounting.

**Critical architectural finding from research:** a pure Proxy-Wasm
"filter-as-the-proxy" pattern (filter making `dispatch_http_call` to the upstream
provider itself, then writing the response via `send_http_response`) **breaks SSE
streaming** because `dispatch_http_call` buffers the *entire* upstream response before
`on_http_call_response` fires : there is no streaming callout variant in the Proxy-Wasm
ABI v0.2.1. For SSE chat completions, the client would receive the whole body at once
instead of token-by-token, defeating streaming UX.

Therefore this spec uses a **hybrid architecture**:
- **Lua access-phase plugin** picks the target and rewrites the request (URL, auth
  header, body) before nginx's normal `proxy_pass` proceeds : giving native SSE
  streaming through the live upstream connection AND free nginx `proxy_next_upstream`
  retry semantics for failover on 429/5xx before response finalization.
- **Rust Proxy-Wasm filter** implements the **runtime state**: weighted-LB counters,
  circuit-breaker opens/closes, latency EWMA, usage tracking via shared_data with CAS
  : accessed by the Lua plugin through a sidecar HTTP API exposing the shared state
  (the wasm guest cannot be called from Lua; the sidecar mirror is the bridge). Or:
  the LB target selection itself runs in the Wasm filter and writes its decision as a
  request header that the Lua plugin reads. The latter is cleaner : see Section 5.

This hybrid mirrors what `ai-proxy-advanced` itself does internally (it's a Lua EE
plugin running in access + balancer phases, calling Kong PDK `kong.service.set_*`
to point nginx at the chosen provider).

---

## 1. Architecture

```
   request  ----->  FILTER CHAIN (in chain order):
                   |
                   v
                   [ auth-oidc | auth-ldap ]  (PRIORITY 1000+) --
                   |                          injects X-Tenant-ID/X-User-ID/X-Routing-Tier
                   v
                   [ redact ]  (PRIORITY 1100)
                   |
                   v  (poi map stashed in kong.ctx.plugin)
                   [ CACHE Lua plugin: redactor's pre-redact body ]  (PRIORITY -- )
                   v
                   [ failover-proxy (Lua access, PRIORITY 824) ]
                   |  reads shared LB state via dispatch_http_call to failover-filter sidecar
                   |  picks target -> rewrites request via kong.service.request.set_url/set_header
                   |  sets X-Failover-Skip to tell Wasm filter "trust my decision"
                   v
                   [ failover-state (Rust Wasm, dispatch-ready filter) ]
                   |  in on_http_request_headers: if header X-Failover-Skip=false or absent,
                   |    compute target via shared_data CAS algorithm, set header
                   |    X-Failover-Decision="<provider>:<model>"
                   v
                   proxy_pass (native nginx upstream load balancing across multiple Kong
                   Upstreams, one per target --- using proxy_next_upstream semantics for
                   429/5xx retry)
                   |
                   v  UPSTREAM PROVIDER
                   (OpenAI / Azure / Bedrock / vLLM)
```

Wait : the Rust Wasm filter runs AFTER the Lua access plugin (Kong runs Lua plugins
in PRIORITY order, then Wasm filters per filter-chain). This means the Lua plugin,
which needs the chosen target, cannot wait on the wasm filter's decision via a header
(the wasm filter hasn't run yet).

**Revise the architecture**: the Lua plugin delegates LB decisions via `dispatch_http_call`
to a **separate sidecar** that is the Rust "failover state service" (NOT a Proxy-Wasm
filter at all : it runs as a normal Rust binary with a small http server). Or : simpler
: **do everything in Lua** using `lua-resty-redis` or lua-resty-mlcache for shared state
in the `ngx.shared.dict` zone, since lua plugins have full cosocket access in `access`.

After consideration, the cleanest architecture is:

### Final Architecture (Lua-first)

1. **`failover` Lua Kong plugin** runs in `access` phase (cosockets available). It owns
   EVERYTHING: target selection, request rewrite, header stripping, `stream_options`
   injection, provider format translation. For state, it uses Kong's built-in
   `ngx.shared.dict` (worker-shared, cross-worker via shdict semantics : same as
   Kong's own `kong-api-health-checker`).
2. **Multi-target Kong Upstreams** (one per provider): declared in `kong.conf` /
   declarative config; nginx's `proxy_next_upstream` retries on 429/5xx automatically
   via the upstream's balancer failover_criteria. The Lua plugin picks which upstream
   to point at via `kong.service.set_upstream(target_name)` per request.
3. **No custom Rust Proxy-Wasm filter for this plugin**. The research confirmed the
   alternative (`filter-as-proxy` for streaming) does NOT work because
   `dispatch_http_call` buffers. Lua + shdict + `set_upstream` is the proven Kong-native
   pattern.

This is therefore a **Lua plugin spec**, similar in surface to `PLUGIN-REDACT-LUA.md`,
plus a Rust binary for provider format translation heavy lifting (Bedrock SigV4,
Anthropic-OpenAI body mapping) exposed as a sidecar. The Lua plugin is also a thin shell
in the heavy-translation case.

---

## 2. Final Hybrid Architecture (Lua + optional Rust translator sidecar)

```
   request  ----->  [ auth-* ]  (PRIORITY 1000+)
                   v
                   [ redact ]  (PRIORITY 1100, Lua)
                   v
                   [ semantic-cache ]  (PRIORITY 910, Rust Proxy-Wasm filter -- short-circuits on HIT)
                   v
                   [ failover ]  (PRIORITY 824, Lua)
                   |  reads kong.ctx.plugin.x-cache == "MISS" or absent
                   |  if MISS -> upstream short-circuit by cache plugin already done; skip
                   |  pick target by algorithm + circuit-breaker state
                   |  rewrite request: URL (per provider), auth header, body (Bedrock only)
                   |  if stream:true -> inject stream_options.include_usage: true
                   |  translate body via translator sidecar if Bedrock
                   |  kong.service.set_upstream(<target name>)  ; sets proxy_pass target
                   |  enable nginx proxy_next_upstream retry on 429/5xx for the Kong upstream
                   v
                   nginx proxy_pass -> provider (OpenAI / Azure / Bedrock / vLLM)
                   v
                   SSE streams through unchanged --> client
```

**State lives in `ngx.shared.dict` (shdict):** `kong_shared_failover_state` zone, declared
via `KONG_NGINX_HTTPS_KONG_SHARED_FAILOVER_STATE=16m`. Storing per-target
`{fails, opened_until, ewma_latency_ms, usage_tokens}` keyed by target id; Lua shdict
operations `/atomic` for CAS-style updates; `lua-resty-core` `ngx.shared.DICT:add` /
`replace` / `incr` primitives.

---

## 3. `schema.lua`

```lua
local typedefs = require "kong.db.schema.typedefs"

return {
  name = "failover",
  protocols = typedefs.protocols_http,
  fields = {
    { config = {
        type = "record", required = true,
        fields = {
          { targets = {
              type = "array", required = true,
              elements = {
                type = "record",
                fields = {
                  { name          = { type = "string", required = true } },  -- matches a Kong Upstream entity name
                  { provider     = { type = "string", required = true, enum = {"openai","azure","bedrock","anthropic","vllm"} } },
                  { model        = { type = "string", required = true } },     -- for OpenAI/vllm; deployment id for Azure
                  { weight       = { type = "integer", default = 100, between = {1, 65535} } },
                  { options = { type = "record", fields = {
                      { azure_api_version      = { type = "string", default = "2024-06-01" } },
                      { azure_instance         = { type = "string" } },
                      { bedrock_region         = { type = "string" } },
                      { anthropic_version      = { type = "string", default = "bedrock-2023-05-31" } },
                  } } },
                  { auth = { type = "record", fields = {
                      { header_name  = { type = "string", default = "Authorization" } },
                      { header_value = { type = "string", referenceable = true } },   -- "Bearer {{vault:secret/ai/openai_key}}"
                      { allow_override = { type = "boolean", default = false } },
                  } } },
                  { description   = { type = "string" } },
                }
              } } },
          { balancing = { type = "record", required = true, fields = {
              { algorithm = { type = "string", required = true, enum = {"round-robin","consistent-hashing","least-connections","lowest-latency","lowest-usage","priority"}, default = "round-robin" } },
              { retries = { type = "integer", default = 3, between = {0, 32767} } },
              { slots = { type = "integer", default = 10000, between = {10, 65536} } },
              { hash_on_header = { type = "string", default = "X-Kong-LLM-Request-ID" } },
              { latency_strategy = { type = "string", enum = {"e2e","tpot"}, default = "tpot" } },
              { tokens_count_strategy = { type = "string", enum = {"total-tokens","prompt-tokens","completion-tokens","cost"}, default = "total-tokens" } },
              { max_fails = { type = "integer", default = 0, between = {0, 32767} } },  -- 0 disables circuit breaker
              { fail_timeout_ms = { type = "integer", default = 10000 } },              -- circuit breaker cooldown
              { failover_criteria = { type = "array", elements = { type = "string", enum = {"error","timeout","invalid_header","http_429","http_500","http_502","http_503","http_504","non_idempotent"} }, default = {"error","timeout"} } },
          } } },
          { translator_url = { type = "string", default = "http://127.0.0.1:8090", description = "Rust translator sidecar for Bedrock/Anthropic body conversion" } },
          { translator_timeout_ms = { type = "integer", default = 500 } },
          { translator_enabled_for = { type = "array", elements = { type = "string", enum = {"bedrock","anthropic"} }, default = {"bedrock"} } },
          { strip_context_headers = { type = "boolean", default = true } },
          { force_stream_options = { type = "boolean", default = true } },
          { llm_format = { type = "string", default = "openai", enum = {"openai","anthropic","bedrock","cohere","gemini","huggingface"} } },
          { upstream_connect_timeout_ms = { type = "integer", default = 60000 } },
          { upstream_read_timeout_ms    = { type = "integer", default = 600000 } },     -- long for slow streaming
          { upstream_write_timeout_ms   = { type = "integer", default = 60000 } },
        }
    } },
  },
}
```

`PRIORITY = 824` (above ai-proxy ~750, below redact 1100).

---

## 4. Phases Hooked

| Phase | Action |
|-------|--------|
| `access` | Pick target by algorithm + circuit-breaker state; rewrite request; translate body if needed; `set_upstream` |
| `balancer` | (Kong's own balancer phase runs here; the Lua plugin only sets metadata via `kong.service.set_upstream`) |
| `header_filter` | Stamp `X-Kong-LLM-Model`, `X-Failover-Target` on response (consumed by telemetry) |
| `log` | Increment per-target counters: usage_tokens, success/failure; update ewma_latency |

---

## 5. `access` Phase

```lua
local balancer = require "kong_balancer"            -- this plugin's decision module
local shdict   = ngx.shared.kong_shared_failover_state
local httpc    = require("resty.http").new()

function FailoverHandler:access(conf)
  local ctx = kong.ctx.plugin
  -- If cache hit, skip routing entirely -- upstream already short-circuited.
  if kong.response.get_header("X-Cache") == "HIT" then return end

  -- 1. Filter healthy targets (circuit-breaker state).
  local targets = conf.targets
  local healthy = {}
  local now = ngx.now() * 1000
  for _, t in ipairs(targets) do
    local opened_until = shdict:get("cb:" .. t.name .. ":opened_until") or 0
    if opened_until == 0 or now > opened_until then
      healthy[#healthy+1] = t
    end
  end
  if #healthy == 0 then
    -- All targets tripped; allow one half-open probe (the highest priority target).
    local probe = balancer.highest_priority(targets, conf)
    healthy = { probe }
    shdict:set("probe:" .. probe.name, true, 30)  -- 30s probe window
  end

  -- 2. Pick target by algorithm.
  local chosen = balancer.pick(healthy, conf.balancing, shdict, kong)

  -- 3. On failure to pick (e.g. shared_data unavailable), fail-closed 503.
  if not chosen then
    return kong.response.exit(503, { error = "no healthy target", reason = "balancer" })
  end

  -- 4. Tag for circuit breaker tracking.
  ctx.failover_target = chosen.name

  -- 5. Rewrite upstream URL based on provider.
  local upstream_url
  if chosen.provider == "openai" then
    upstream_url = "https://api.openai.com/v1/chat/completions"
  elseif chosen.provider == "azure" then
    upstream_url = string.format("https://%s.openai.azure.com/openai/deployments/%s/chat/completions?api-version=%s",
                 chosen.options.azure_instance, chosen.model, chosen.options.azure_api_version or "2024-06-01")
  elseif chosen.provider == "vllm" then
    upstream_url = chosen.options.upstream_url  -- provided per-target
  elseif chosen.provider == "bedrock" then
    -- Bedrock signing is heavy; do in translator sidecar.
    local body = kong.service.request.get_raw_body()
    local tr_res = httpc:request_uri(conf.translator_url .. "/bedrock/translate", {
      method = "POST",
      body = body,
      headers = {
        ["Content-Type"] = "application/json",
        ["X-Bedrock-Model"] = chosen.model,
        ["X-Bedrock-Region"] = chosen.options.bedrock_region,
        ["X-Bedrock-Stream"] = kong.service.request.get_header("x-stream-mode") or "false",
      },
    })
    if tr_res.status ~= 200 then
      return kong.response.exit(500, { error = "translator_failed", detail = tr_res.body })
    end
    -- The translator sidecar replaces body + injects signed headers already (HMAC path) OR
    -- returns the body + metadata for the Lua plugin to apply (URL/signature here).
    kong.service.request.set_raw_body(tr_res.body)
    upstream_url = string.format("https://bedrock-runtime.%s.amazonaws.com/model/%s/invoke%s",
                 chosen.options.bedrock_region, chosen.model, (parsed.stream and "-with-response-stream" or ""))
    -- SigV4 headers (provided by translator) injected via kong.service.request.set_header
    for k, v in pairs(parse_signed_headers(tr_res.headers["X-Signed-Headers"])) do
      kong.service.request.set_header(k, v)
    end
    goto after_url
  end
  kong.service.request.set_url(upstream_url)

  ::after_url::

  -- 6. Auth header (per target).
  if not chosen.auth.allow_override then
    -- The strip-context-headers below removes x-tenant-id etc.
    kong.service.request.set_header(chosen.auth.header_name, chosen.auth.header_value)
  end

  -- 7. Force stream_options.include_usage for billing-grade accounting
  --    (only OpenAI/Azure support this; vLLM is OpenAI-compat; Bedrock uses
  --    its own response usage field which the translator maps).
  if conf.force_stream_options and (chosen.provider == "openai" or chosen.provider == "azure" or chosen.provider == "vllm") then
    local body = kong.service.request.get_raw_body()
    if body and body ~= "" then
      local ok, parsed = pcall(cjson.decode, body)
      if ok and parsed.stream == true then
        parsed.stream_options = parsed.stream_options or {}
        parsed.stream_options.include_usage = true
        kong.service.request.set_raw_body(cjson.encode(parsed))
      end
    end
  end

  -- 8. Strip context headers before egress (PII / identity not for LLM providers)
  if conf.strip_context_headers then
    kong.service.request.clear_header("X-Tenant-ID")
    kong.service.request.clear_header("X-User-ID")
    kong.service.request.clear_header("X-Routing-Tier")
    kong.service.request.clear_header("X-Token-Scopes")
    kong.service.request.clear_header("X-Token-Issuer")
  end

  -- 9. Set Kong upstream to the chosen target.
  --    This registers the chosen target with nginx's balancer; Kong's multi-upstream
  --    entity must contain all targets of this provider as same-name Kong Upstreams
  --    (declared in decK) so that proxy_next_upstream retry can switch to alternates on
  --    429/5xx.
  kong.service.set_upstream(chosen.name)

  -- 10. Auto retry on failover_criteria (nginx-level via Kong upstream's balancer config).
  --     The Kong upstream entity itself carries proxy_next_upstream semantics.
  --     Lua plugin only sets the routing decision; nginx retries on 429/5xx as
  --     configured in the upstream's `healthchecks`/`retries`/`slots` fields.
end
```

---

## 6. Balancing Algorithms

Each implemented in `kong_balancer.lua`. Uses `ngx.shared.dict` for cross-worker shared
state.

### 6.1 `round-robin` (weighted)

```lua
function M.pick_rr(targets, conf, shdict)
  local key = "lb:rr_idx"
  -- ngx.shared.DICT:incr is atomic across workers (shdict semantics).
  -- Force a value into the [1, #targets] range with modulo, weighting via repetition.
  local idx, _ = shdict:incr(key, 1, 0)  -- atomic; default 0
  -- Build a weighted slot list once at startup; here just use the array index modulo.
  local slots = weighted_slots(targets)  -- {t1, t1, t2, ...} per weight
  return slots[(idx % #slots) + 1]
end
```

### 6.2 `consistent-hashing`

Ketama-style ring built from config (computation at startup, no runtime shared state).
Lookup by `hash_on_header` value (default `X-Kong-LLM-Request-ID`); if absent,
`kong.request.get_header(x-request-id)` is used as fallback. Per-request sticky.

### 6.3 `least-connections`

Per-target active counter in shdict, +1 on dispatch, -1 on response completion (in
`access`/`log` phases respectively). Picks the fewest-active. Uses:
- `shdict:incr("lc:" .. name, 1, 0)` in access
- `shdict:incr("lc:" .. name, -1)` in log

### 6.4 `lowest-latency`

Per-target rolling EWMA. Updated in `log` phase using `ngx.now() - ctx.dispatch_time_ms`.
Stored as `Float64` bytes (or use `ngx.shared.DICT`'s typed `set_float` API).

### 6.5 `lowest-usage`

Per-target cumulative tokens (or cost) over a rolling window. Best-effort : the log
phase increments counters asynchronously; reads see stale numbers. This is the same
limitation Kong's `ai-proxy-advanced` hits (cross-worker realtime is impractical).

### 6.6 `priority`

Ordered priority groups by config order. Within a group, round-robin. Failover to the
next group only on circuit-breaker trip.

### 6.7 (NOTE: `semantic` algorithm lives in `PLUGIN-SEMANTIC-CACHE` (from
`ai-proxy-advanced`'s semantic routing) : out of scope here; if you need semantic
routing by-prompt-toward-model, use the cache filter's vector+description lookup
pattern.)

---

## 7. Circuit Breaker (per target)

State per target in shdict:
- `cb:<name>:fails:u32`
- `cb:<name>:opened_until:u64_ms`

Algorithm (matches Kong's `max_fails`/`fail_timeout`, nginx semantics):
1. In `log` phase: if the request's upstream status matches a `failover_criteria`
   entry (excluding `http_403`/`http_404` which Kong says never count for CB): increment
   `fails` (`shdict:incr`).
2. If `fails >= max_fails`: set `opened_until = now + fail_timeout_ms`, reset `fails = 0`.
3. In `access` phase pick-time: skip targets whose `opened_until > now`.
4. `max_fails = 0` disables the circuit breaker entirely for the target (Kong ref).

**Cross-worker correctness:** shdict (the `ngx.shared.DICT` zone) is shared across
worker processes within nginx. `incr` operations are atomic. The CB state is therefore
cross-worker-accurate.

For cross-process (multiple Kong pods) CB state, you'd need Redis as a backing
shdict (lua-resty-mlcache supports redis backends). v1 stays in-process shdict;
document the limitation.

---

## 8. Provider Format Translation

### 8.1 OpenAI (passthrough)

No translation. URL `https://api.openai.com/v1/chat/completions`; `Authorization:
Bearer <key>`.

### 8.2 Azure OpenAI

URL rewrite to deployment-based path. `api-key: <key>` replaces `Authorization: Bearer`.
Body fields: same as OpenAI (`model` ignored; deployment-id is `model_name` config).
`stream_options.include_usage` supported on api-version ≥ `2024-06-01` : confirm your
pinned api-version.

### 8.3 vLLM

OpenAI-compatible. URL override per target. Body passthrough (we still inject
`stream_options`).

### 8.4 AWS Bedrock (heavy translation → sidecar)

The translator sidecar (small Rust binary using `aws-sigv4` or hand-rolled SigV4) handles:
1. Body conversion OpenAI-shape → Anthropic Messages shape OR Bedrock Converse, per
   model family (Claude vs Nova vs Llama).
2. SigV4 signing (HMAC-SHA256 over canonical request) : `aws-sigv4` crate pulls in
   heavy AWS deps; cleaner with a hand-rolled SigV4 using `sha2` + `hmac` (~200 LoC).
   Or use `reqsign` (lightweight Rust SigV4 helper).
3. URL rewrite to `bedrock-runtime.{region}.amazonaws.com/model/{id}/invoke[-with-response-stream]`.
4. Stream variant uses `InvokeModelWithResponseStream`; the SSE events are Bedrock-specific
   (not OpenAI `chat.completion.chunk` shape) and require translation back to OpenAI on
   the response. The translator sidecar handles BOTH directions through a single
   pass-through proxy mode: the Lua plugin sends Bedrock requests through the
   translator, which **bi-directionally streams** the response (translator → client)
   translating event-by-event. This is required because the Bedrock response stream
   shape differs from OpenAI's, and Kong's `kong.service.set_upstream` doesn't
   translate event contents.

**So Bedrock target's upstream is NOT the AWS endpoint; it's the translator sidecar
itself**, which proxies to AWS internally (and translates both directions in the
stream). The translator sidecar must support streaming via Tokio + hyper (it can,
since it's a native binary with threads).

### 8.5 Anthropic (direct API)

If using the Anthropic API natively (not via Bedrock), the body is Anthropic Messages
shape, similar to Bedrock's Claude shape. Translation order: OpenAI messages → Anthropic
(hoist `system` role out of messages; content parts shape `[{type:"text",text:…}]`;
`stop` → `stop_sequences`). Same translator sidecar handles this with a different
endpoint (`POST /anthropic/translate`).

---

## 9. Translator Sidecar (Rust binary)

For Bedrock and direct Anthropic flows, a small Rust binary with an axum server exposes
`POST /bedrock/proxy` (bi-directional pass-through with translation) and
`POST /anthropic/translate` (one-shot body translation). The Bedrock path is a proxy
(it terminates the upstream connection to AWS and re-sends to the client as OpenAI
SSE); the Anthropic path is a body-only translation (the client streams directly from
Anthropic after the rewrite).

### Cargo.toml

```toml
[package]
name = "failover-translator"
version = "1.0.0"
edition = "2021"
[dependencies]
axum = { version = "0.7", features = ["ws"] }
tokio = { version = "1", features = ["full"] }
hyper = { version = "1", features = ["full"] }
reqwest = { version = "0.12", features = ["json","stream"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tokio-stream = "0.1"
futures = "0.3"
sha2 = "0.10"
hmac = "0.12"
hex = "0.4"
chrono = "0.4"
tracing = "0.1"
tracing-subscriber = "0.3"
anyhow = "1"
reqsign = { version = "0.16", optional = true }

[features]
default = ["aws-sigv4-handrolled"]
aws-sigv4-handrolled = []
aws-sigv4-reqsign  = ["dep:reqsign"]
```

The translator is pure-Rust native binary (NOT wasm). Bilingual translation maps:

```rust
// Bedrock invoke event (Anthropic-shape) → OpenAI chat.completion.chunk
fn from_bedrock_event_to_openai_chunk(ev: &BedrockStreamEvent) -> OpenAiChunk { ... }
// OpenAI request → Anthropic Messages body
fn from_openai_request_to_anthropic_body(req: OpenAiRequest) -> AnthropicReq { ... }
```

---

## 10. Failure Modes

| Failure | Detection | Behavior |
|---------|-----------|----------|
| No healthy target (all CB tripped) | balancer returns nil | 503 `no_healthy_target` |
| Translator sidecar down (Bedrock target chosen) | httpc:request_uri nil/timeout | 503 `translator_unreachable` + never silence |
| Translator 5xx | res.status >= 500 | 502 `translator_failed` |
| Body parse failed (`cjson.decode`) in stream_options injection | pcall returns false | log + pass through unmodified (do NOT 200 silently : emit `X-Failover-Warning: stream-options-inject-failed` so ops sees it) |
| `set_upstream` returns nil (chosen target not a Kong Upstream entity) | call returns false | 503 `target_not_configured` : decK config error; fail closed |
| All retries exhausted (nginx retries via `proxy_next_upstream`) | nginx sends final 5xx | nginx handles response; we stamp `X-Failover-Failed-Criteria: <code>` in header_filter |
| shdict unavailable (SHM zone not declared) | shdict:nil | 500 `shdict_missing` : startup config error; documented in `PLUGIN-FOUNDATION.md` |
| Cache HIT path: upstream never engaged | `X-Cache: HIT` set by cache filter | Skip ; return immediately without rewriting |

**No silent fallback** (Rule 13): every failover failure surfaces a non-2xx or a
`X-Failover-Warning`/`X-Failover-Failed-Criteria` response header. Logs structured
(targets tried, decisions, breaker state).

---

## 11. Telemetry Surfaces

Plugin exposes Lua fields via `kong.log.set_serialize_value` consumed by Vector →
ClickHouse:
- `failover.target_chosen` (target name)
- `failover.algorithm` (round-robin | ...)
- `failover.circuit_opened_count`
- `failover.stream_options_forced` (bool)
- `failover.translator_used` (bool, for Bedrock)
- `failover.balancer_decision_latency_ms`
- `X-Kong-LLM-Model` response header carries the chosen model back so billing joins
  on `model_name` even when client requested a different model name.

These augment the `llm_billing_ledger` schema (PROPOSAL Section 5.3) additions:

```sql
ALTER TABLE llm_billing_ledger
  ADD COLUMN failover_target LowCardinality(String),
  ADD COLUMN failover_algorithm LowCardinality(String),
  ADD COLUMN stream_options_forced Bool DEFAULT false,
  ADD COLUMN translator_used Bool DEFAULT false;
```

---

## 12. decK Configuration Example

Two parts: Kong Upstreams (one per target with multi-target list + healthchecks) and
the failover plugin instance.

### 12.1 Kong Upstream entities

```yaml
upstreams:
  - name: openai-primary
    targets:
      - target: api.openai.com:443
        weight: 100
    healthchecks:
      active:
        type: http
        http_path: /v1/models
        healthy.interval: 30
        unhealthy.interval: 5
      passive:
        type: http
        retries: 3
        # proxy_next_upstream equivalent
  - name: azure-failover
    targets:
      - target: prod-deployment.azure.openai.com:443
        weight: 100
  - name: vllm-local
    targets:
      - target: vllm.corp.internal:8000
        weight: 100
```

The failover plugin's `targets[].name` references these upstream names. nginx retries
across targets in `proxy_next_upstream` style only WITHIN one Kong Upstream; cross-upstream
failover is the plugin's `set_upstream` decision (one upstream at a time per request).

For cross-Kong-upstream retry on 429/5xx, the plugin would need to set a custom
`balancer` callback (`kong.service.set_target_retry_callback`) : opt-in feature for v2.

### 12.2 Plugin install

```yaml
plugins:
  - name: failover
    config:
      targets:
        - { name: "openai-primary", provider: "openai", model: "gpt-4o", weight: 70,
            auth: { header_name: "Authorization", header_value: "Bearer {{vault:secret/ai/openai_key}}" } }
        - { name: "azure-failover", provider: "azure", model: "prod-deployment",
            options: { azure_instance: "azure-us-east-node", azure_api_version: "2024-06-01" },
            weight: 30, auth: { header_name: "api-key", header_value: "{{vault:secret/ai/azure_key}}" } }
      balancing:
        algorithm: lowest-usage
        retries: 3
        max_fails: 5
        fail_timeout_ms: 30000
        failover_criteria: ["error","timeout","http_429","http_502","http_503","http_504","non_idempotent"]
      strip_context_headers: true
      force_stream_options: true
      llm_format: "openai"
      translator_url: "http://failover-translator.sidecar.svc:8090"
      translator_enabled_for: ["bedrock","anthropic"]
```

---

## 13. Combined Streaming + Failover Decision (Important Caveat)

For SSE streaming, **mid-flight failover is not possible** because `proxy_pass` begins
streaming the first SSE event to the client before the failover can determine the
final upstream status. If the first SSE event carries `data: {error: 429}`, the client
has already received it and breaking the stream to retry is not feasible.

**Practical failover in streaming flow:**
1. Failover happens at TLS connect / before the first SSE event : if nginx's
   `proxy_next_upstream http_429` fires BEFORE the first upstream byte, nginx retries
   transparently.
2. Once the first SSE event has been transmitted, failover won't occur on this
   request : the client's `data:` stream terminates abnormally and the client must
   reconnect (standard SSE error handling).
3. For non-streaming requests (`stream:false`), failover is full : `proxy_next_upstream
   http_500` can retry the entire response before sending any bytes to the client.

This matches Kong's commercial `ai-proxy-advanced` behavior (it uses the same nginx
underpinnings). Document this so callers of streaming endpoints know that mid-stream
failover is best-effort; clients should handle SSE termination + reconnect explicitly.

---

## 14. Test Plan (Required)

- Unit (`kong_balancer.lua`): each algorithm with shdict mock : pick deterministic
  outputs for RR, consistent-hash, least-connections (with mocked counters), priority.
- Unit: circuit-breaker state machine : fail N times → opens → closes after
  `fail_timeout_ms` → half-open probe → close on success / re-open on failure.
- Integration: OpenAI target returns 429 : assert non-streaming request retries to
  Azure target; assert response is from Azure (different model name stamped).
- Integration: streaming request with 429 on first connect : assert retry to next
  upstream BEFORE first byte to client succeeds; assert first token from retry target.
- Integration: all targets circuit-broken : assert 503 `no_healthy_target`.
- Integration: Bedrock target via translator : assert body translated to Anthropic
  shape, SigV4 headers set, translator returns parsed OpenAI-shape response.
- Integration: streaming Bedrock (InvokeWithResponseStream) : assert translator
  bi-directional stream emits valid OpenAI `chat.completion.chunk` SSE frames.
- Integration: `force_stream_options: true` : assert `stream_options.include_usage:true`
  injected into OpenAI/Azure/vLLM requests when `stream:true`; NOT injected for Bedrock.
- Integration: strip_context_headers : assert client prompt+identity headers absent
  from upstream request (capture upstream via a test mock).
- Regression: assert no cache HIT request ever goes through failover routing (cache
  plugin short-circuited via `send_http_response`).

---

## 15. Open Questions

| Q | Resolution |
|---|------------|
| Cross-pod CB state | Single-pod shdict default; redis-backed mlcache option for multi-pod |
| Translator body vs proxy for Bedrock streaming | Translator MUST proxy (bi-directional stream) for Bedrock streaming because event-shape differs; for non-streaming Bedrock, body-only translation + sigv4 signing via Lua sidecar calls suffice |
| Retry on cross-Kong-upstream | Native within a Kong Upstream's target list; cross-upstream retry needs custom `set_target_retry_callback` (v2) |
| MS AD credentials for translator vs vault | Vault reference template `{{vault:secret/...}}` : resolved by Kong's secret management at plugin load time |
| | |

---

## 16. References

- Kong `ai-proxy-advanced` reference (algorithm semantics): https://developer.konghq.com/plugins/ai-proxy-advanced/reference/
- Kong circuit-breaker example: https://developer.konghq.com/plugins/ai-proxy-advanced/examples/circuit-breaker/
- Kong `semantic-with-fallback` example: https://developer.konghq.com/plugins/ai-proxy-advanced/examples/semantic-with-fallback/
- Kong Token estimation PR (#12792): https://github.com/Kong/kong/pull/12792
- Kong SSE usage gap issue (#14768): https://github.com/Kong/kong/issues/14768
- Azure OpenAI api-key `:` deployment path: https://www.microsoft.com/en-us/azure/foundry/openai/latest
- Bedrock Invoke / InvokeModelWithResponseStream: https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_InvokeModel.html
- Bedrock Claude request body shape: https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-anthropic-claude-messages-request-response.html
- `aws-sigv4` crate (NOT used, too heavy): https://crates.io/crates/aws-sigv4
- `getrandom` wasm limitations (why we don't sigv4 in the wasm guest): https://github.com/rust-random/getrandom/issues/223
- `reqsign` lightweight Rust SigV4: https://crates.io/crates/reqsign
- `dispatch_http_call` NO streaming downstream (only one-shot body): https://github.com/proxy-wasm/spec/blob/main/abi-versions/v0.2.1/README.md
- `tetratelabs/proxy-wasm-go-sdk` #364 (`SendHttpResponse` post-headers resets conn): https://github.com/tetratelabs/proxy-wasm-go-sdk/issues/364
- Kong PDK `kong.service.set_upstream` (Lua access phase): https://docs.konghq.com/gateway/latest/plugin-development/pdk/service/
- Kong health checks: https://docs.konghq.com/gateway/latest/how-kong-works/health-checks/
- nginx `proxy_next_upstream` semantics: http://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_next_upstream
- `ngx.shared.DICT` atomic incr / cross-worker semantics: https://github.com/openresty/lua-nginx-module#ngxshareddict

---

**End of document.**