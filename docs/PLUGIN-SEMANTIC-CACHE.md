# Plugin Spec: Semantic Cache - Redis VSS Proxy-Wasm Filter

**Document ID:** AMI-PROP-LLMGW-PLUGIN-SEMANTIC-CACHE-v1.0
**Status:** Draft
**Date:** 2026-07-04
**Parent:** `PROPOSAL-LLM-GATEWAY-v2.md`; inherits `PLUGIN-FOUNDATION.md`
**Replaces:** Kong Enterprise `ai-semantic-cache` plugin (`tier: ai_gateway_enterprise`)
**Reference implementation to wrap:** `redis/redis-vl-python` `SemanticCache`

This document specifies the custom Rust Proxy-Wasm filter that implements a semantic
cache for LLM chat completions using Redis Vector Similarity Search (VSS). Because the
Proxy-Wasm guest cannot open TCP sockets (VSS Query is RESP3 over raw TCP), the filter
delegates all embedding computation and Redis operations to an **HTTP shim sidecar**
(co-located, mTLS-required when non-localhost). The filter implements the
double-async pause-dispatch-resume pattern (embedding → cache query → cache store on
miss), enforces cross-tenant / cross-tier isolation, and provides graceful-miss behavior
on every failure path.

---

## 1. Architecture

```
Rust Proxy-Wasm filter (semantic-cache)               Embedding Shim       Cache Shim (VSS)
+------------------------------------+                 (optional)          +--------------------+
| on_http_request_body (EOF)         |                 +-----------+       | redisvl SemanticCache
|   extract prompt from body         |  POST /embed    | call      |       | builds FT.SEARCH   |
|   validate tenant+tier from headers|  -------------> | OpenAI or |       | with TAG pre-filter|
|   dispatch_http_call /embed        |                 | local model|       | (tenant, tier)     |
|   Action::Pause                     |                 +-----------+       +--------------------+
| on_http_call_response (embed token)                                        ^     |
|   validate vector.dim == expected   |                                        |     |
|   dispatch_http_call /cache/query   |  POST /cache/query                     |     |
| on_http_call_response (query token)|  ------------------------------------->|     |
|   if hit: re-hydrate PII (RESTORE)  |                                        |     |
|           send_http_response 200   |  200 {hit:true, distance, ...}         |     |
|   if miss: resume_http_request      |  <-------------------------------------|     |
|                                     |                                        |     |
| on_http_response_body (EOF, miss)  |  POST /cache/store                     |     |
|   dispatch_http_call /cache/store   |  ------------------------------------->|     |
| on_http_call_response (store token)|  200 {stored:true}                     |     |
|   resume_http_response              |                                        |     |
+------------------------------------+                                        v    Redis VSS HNSW
```

The shims can be a single combined service (cache shim includes OpenAI call) or two
distinct sidecars. The spec supports both; default is **one combined Redis+Embedding
shim** for operational simplicity. The contract below assumes one combined shim
exposing all three endpoints.

---

## 2. Constraints Inherited

From `PLUGIN-FOUNDATION.md`:
- `dispatch_http_call` requires hostname/IP (`:authority`), NOT an Envoy cluster/Kong
  upstream (Discussion #564). Configure the shim as `127.0.0.1:8090` (localhost) or
  its DNS name.
- Pseudo-headers `:method`/`:path`/`:authority` mandatory.
- `dispatch_http_call` buffers the whole response body before `on_http_call_response`
  fires : no streaming sidecar responses. This means the embedding sidecar must return
  the 3072-dim vector in a single HTTP body (fine : it is well under 24KB).
- `Action::Pause` only valid in `on_http_request_headers`, `on_http_request_body`,
  `on_http_response_body`, `on_http_call_response`.
- Concurrent dispatches (embed + query + store) tracked by `dispatch_http_call` token
  ID; route by token in `on_http_call_response` via a `HashMap<u32, Phase>` per stream.

---

## 3. `meta.json` `config_schema`

```json
{
  "config_schema": {
    "type": "object",
    "properties": {
      "shim_cluster":      { "type": "string", "description": "ip or host:port of the cache+embedding shim sidecar" },
      "shim_timeout_ms":   { "type": "integer", "default": 2000 },
      "embedding_dim":     { "type": "integer", "default": 3072 },
      "distance_threshold":{ "type": "number", "default": 0.10, "description": "cosine distance [0-2]; lower is stricter; 0.10 ~ 0.95 cosine similarity" },
      "cache_ttl_seconds": { "type": "integer", "default": 300 },
      "isolated_fields": {
        "type": "array",
        "items": { "type": "string" },
        "default": ["x-tenant-id", "x-routing-tier"],
        "description": "Request headers used as cache isolation key. Both MUST be present (enforced)."
      },
      "stop_on_failure":   { "type": "boolean", "default": false, "description": "Kong default false: cache errors degrade to miss" },
      "message_countback": { "type": "integer", "default": 1, "description": "Number of trailing chat messages to embed (history window)" },
      "ignore_system_prompts": { "type": "boolean", "default": true }
    },
    "required": ["shim_cluster"]
  }
}
```

---

## 4. Shim HTTP API Contract

### 4.1 `POST /embed`

Request:
```json
{
  "messages": [
    {"role": "user", "content": "How do I file a PTO request?"}
  ],
  "message_countback": 1,
  "ignore_system_prompts": true,
  "embedding_dim": 3072
}
```

Response (200):
```json
{
  "vector": [0.0123, -0.0456, ...],
  "dim": 3072,
  "prompt_text": "How do I file a PTO request?"
}
```

The shim calls OpenAI's `/v1/embeddings` (`text-embedding-3-large`) or runs a local
embedding model. The shim holds the OpenAI API key; the guest never sees it. The
returned `dim` must equal `embedding_dim`; on mismatch the guest treats as MISS.

### 4.2 `POST /cache/query`

Request:
```json
{
  "vector": [0.0123, -0.0456, ...],
  "dim": 3072,
  "tenant": "tenant-123",
  "tier": "standard",
  "num_results": 1,
  "return_fields": ["response", "stream_mode", "format", "redact_key"]
}
```

Response (200) : **HIT**:
```json
{
  "hit": true,
  "distance": 0.034,
  "similarity": 0.966,
  "entry_id": "semcache:tenant-123:standard:9f3c...",
  "response": "<cached response body as stored>",
  "stream_mode": "sse",
  "format": "openai",
  "redact_key": null
}
```

Response (200) : **MISS** (NOT an error):
```json
{ "hit": false }
```

Response (5xx) : see Section 11 (failure modes): shim must surface Redis/embedding
errors as 5xx; the guest treats 5xx as MISS (with `X-Cache-Error` response header
surfaced).

### 4.3 `POST /cache/store`

Request:
```json
{
  "vector": [0.0123, -0.0456, ...],
  "dim": 3072,
  "tenant": "tenant-123",
  "tier": "standard",
  "prompt": "How do I file a PTO request?",
  "response": "<LLM response body, redacted post-PII-restoration>",
  "stream_mode": "json",
  "format": "openai",
  "ttl": 300
}
```

Response (200): `{"stored": true, "entry_id": "..."}`

### 4.4 `GET /healthz`

`{"ok": true, "redis_ok": true, "embeddings_ok": true}` (503 on any false).

### 4.4.1 Common response headers

- `X-Shim-Latency-Ms`: integer, propagated to audit log.
- `X-Shim-Hit`: `"true"`/`"false"` (only on `/cache/query`).

---

## 5. Redis VSS Schema (shim-internal)

### 5.1 Index creation (one-time at shim startup)

```
FT.CREATE idx:semcache ON HASH PREFIX 1 semcache:
  SCHEMA
    tenant       TAG
    tier         TAG
    prompt       TEXT
    response     TEXT
    embedding    VECTOR HNSW 6
      TYPE FLOAT32
      DIM 3072
      DISTANCE_METRIC COSINE
      M 16
      EF_CONSTRUCTION 200
      EF_RUNTIME 10
```

Single shared index (Option 2 from research). Per-tenant physical isolation (Option 1,
separate index per tenant) is supported if a tenant entry's `index_name` overrides
the default : the shim accepts `index_name` in the `/cache/query` body for fallback.

### 5.2 Hybrid TAG + KNN query (per request)

```sql
FT.SEARCH idx:semcache
  "(@tenant:{tenant-123} @tier:{standard})=>[KNN 1 @embedding $qvec AS distance]"
  PARAMS 2 qvec <3072-float32-binary-blob>
  LIMIT 0 1
  RETURN 5 distance response stream_mode format redact_key
  DIALECT 2
```

Redis 8's `ADHOC_BF` filter mode gives exact KNN on the small per-tenant subset
(automatic unless `HYBRID_POLICY=BATCHES` configured). The shim converts the JSON
`vector` array to a little-endian `FLOAT32` binary blob via `struct.pack`.

### 5.3 Hash entry shape + TTL

```
HSET semcache:tenant-123:standard:<uuid>
  embedding  <fp32-blob>
  prompt     "<prompt>"
  response   "<redacted-response-or-original>"
  stream_mode "json" | "sse"
  format      "openai"
  tenant      "tenant-123"
  tier        "standard"
  created_at  "<iso8601>"
EXPIRE semcache:tenant-123:standard:<uuid> <ttl>
```

Redis 8's RediSearch honours key-level `EXPIRE` at query-time (expired entries filtered
before being returned). `HSET` overwriting the embedding re-trains the HNSW entry
in place.

### 5.4 Distance semantics

`COSINE` distance is in `[0, 2]` (0 = identical, 2 = opposite). The shim interprets
`distance_threshold = 0.10` as "hit if returned `distance <= 0.10`" : equivalent to
**cosine similarity >= 0.90**. Matches Kong's semantics (Kong defaults `threshold: 0.2`
cosine distance for OpenAI 3072d embeddings).

---

## 6. Cross-Tenant / Cross-Tier Isolation

- **Mandatory**: the filter rejects (403) any request missing `x-tenant-id` or
  `x-routing-tier` headers (configured via `isolated_fields` : defaults to those two).
  Missing isolation metadata is a security failure, not a cache failure.
- **Single shared index + TAG pre-filter** for tenant+tier (default, recommended).
  The TAG filter is applied BEFORE the KNN search (Redis `ADHOC_BF` hybrid policy by
  default on small result sets : exact KNN, no recall loss).
- A tenant-456 request can NEVER see tenant-123 entries because the query string
  carries `@tenant:{tenant-456}` and Redis pre-filters before ranking.
- **Optional per-tenant physical isolation** by `index_name` override in the shim
  request body : for regulatory-strict tenants (separate FT.CREATE per tenant at
  provisioning time). The shim accepts `index_name` in `/cache/query`.

---

## 7. Lifecycle Implementation

### 7.1 State

```rust
struct SemCacheFilter {
    config: Config,
    body_buffer: Vec<u8>,                // accumulates body chunks until EOF
    tenant: String,
    tier: String,
    vector: Option<Vec<f32>>,            // after embed
    prompt_text: Option<String>,
    request_body_original: Vec<u8>,      // kept for forwarding on MISS
    phase: Phase,
    pending_tokens: HashMap<u32, Phase>, // multiple in-flight dispatches
    cache_response_body: Option<Vec<u8>>, // for store-after-response
    cache_stream_mode: String,
}

enum Phase {
    None, AwaitEmbed, AwaitQuery, AwaitStore, Done,
    Failed(&'static str),                // any infra failure -> MISS path
}
```

### 7.2 `on_http_request_headers`

```rust
fn on_http_request_headers(&mut self, _: usize, _: bool) -> Action {
    // Read isolation headers enforced.
    let tenant = match self.get_http_request_header("x-tenant-id") {
        Some(t) if !t.is_empty() => t,
        _ => {
            return self.missing_isolation();
        }
    };
    let tier = match self.get_http_request_header("x-routing-tier") {
        Some(t) if !t.is_empty() => t,
        _ => {
            return self.missing_isolation();
        }
    };
    self.tenant = tenant;
    self.tier = tier;
    Action::Continue                                    // wait for body phase
}
```

### 7.3 `on_http_request_body` (buffered to EOF, then dispatch)

```rust
fn on_http_request_body(&mut self, body_size: usize, eof: bool) -> Action {
    if !eof {
        // Accumulate chunks (Action::Pause requests body buffering).
        if let Some(more) = self.get_http_request_body(0, body_size) {
            self.body_buffer.extend_from_slice(&more);
        }
        return Action::Pause;                           // keep buffering
    }
    // EOF : final chunk
    if let Some(more) = self.get_http_request_body(0, body_size) {
        self.body_buffer.extend_from_slice(&more);
    }
    self.request_body_original.clone_from(&self.body_buffer);
    // Kick off embedding dispatch.
    match self.dispatch_embed() {
        Ok(tok) => { self.phase = Phase::AwaitEmbed; self.pending_tokens.insert(tok, Phase::AwaitEmbed); Action::Pause }
        Err(_)  => self.miss_and_continue(),
    }
}
```

### 7.4 `on_http_call_response` (router)

```rust
fn on_http_call_response(&mut self, token: u32, nh: usize, bs: usize, _nt: usize) {
    if nh == 0 && bs == 0 {
        return self.handle_dispatch_timeout(token);
    }
    let phase = self.pending_tokens.get(&token).copied().unwrap_or(Phase::None);
    match phase {
        Phase::AwaitEmbed => self.on_embed_response(bs),
        Phase::AwaitQuery => self.on_query_response(bs),
        Phase::AwaitStore => self.on_store_response(bs),
        _ => {
            self.send_http_response(500, vec![], Some(b"unexpected token\n"));
        }
    }
}
```

### 7.5 Embed response handler

```rust
fn on_embed_response(&mut self, bs: usize) {
    let body = self.get_http_call_response_body(0, bs).unwrap_or_default();
    let embed_resp = match serde_json_wasm::from_slice::<EmbedResp>(&body) {
        Ok(r) => r,
        Err(_) => { return self.miss_and_continue_with_header("X-Cache-Error", "embed-malformed"); }
    };
    if embed_resp.dim != self.config.embedding_dim as usize {
        // CRITICAL: a dim mismatch fed to Redis silently indexes as garbage and
        // returns wrong "similar" results. Treat as MISS, never store.
        return self.miss_and_continue_with_header("X-Cache-Error", "embed-dim-mismatch");
    }
    self.vector = Some(embed_resp.vector);
    self.prompt_text = embed_resp.prompt_text;
    // Dispatch cache query.
    match self.dispatch_query() {
        Ok(tok) => { self.phase = Phase::AwaitQuery; self.pending_tokens.insert(tok, Phase::AwaitQuery); }
        Err(_) => self.miss_and_continue(),
    }
}
```

### 7.6 Query response handler

```rust
fn on_query_response(&mut self, bs: usize) {
    let body = self.get_http_call_response_body(0, bs).unwrap_or_default();
    let q_resp = match serde_json_wasm::from_slice::<QueryResp>(&body) {
        Ok(r) => r,
        Err(_) => { return self.miss_and_continue_with_header("X-Cache-Error", "query-malformed"); }
    };
    if !q_resp.hit {
        // MISS: forward to upstream, capture the response for store.
        self.set_http_request_header("x-cache", Some("MISS"));
        self.phase = Phase::Done;                       // response capture will trigger store
        self.resume_http_request();
        return;
    }
    // HIT : short-circuit. Re-hydrate PII if upstream pipeline stashed a redact_key.
    let final_body = if let Some(redact_key) = q_resp.redact_key {
        self.rehydrate_from_redact_key(&q_resp.response, &redact_key)
            .unwrap_or_else(|_| q_resp.response.clone())
    } else {
        q_resp.response.clone()
    };
    // Frame per requested stream_mode (Section 8).
    let (content_type, body) = self.frame_response(&q_resp.stream_mode, &self.request_body_original, &final_body);
    self.set_http_response_header("x-cache", Some("HIT"));
    self.set_http_response_header("content-type", Some(&content_type));
    self.send_http_response(200, vec![], Some(&body));
    // Note: send_http_response short-circuits; the downstream stream's body is never
    // proxied upstream. The Redaction Lua plugin's body_filter MAY still fire on the
    // synthetic response : verify per Kong version. SAFER: re-hydration done inline
    // above (no dependence on downstream redaction running).
}
```

### 7.7 Store-after-response

```rust
fn on_http_response_body(&mut self, body_size: usize, eof: bool) -> Action {
    // On MISS path only; HIT path already short-circuited.
    if !eof {
        // Buffer upstream response to EOF.
        if let Some(more) = self.get_http_response_body(0, body_size) {
            self.cache_response_body = match self.cache_response_body.take() {
                Some(mut v) => { v.extend_from_slice(&more); Some(v) },
                None => Some(more.to_vec()),
            };
        }
        return Action::Pause;                           // keep buffering
    }
    // EOF : dispatch store.
    if let Some(body) = self.cache_response_body.take() {
        match self.dispatch_store(&body) {
            Ok(tok) => { self.phase = Phase::AwaitStore; self.pending_tokens.insert(tok, Phase::AwaitStore); Action::Pause }
            Err(_) => {
                self.set_http_response_header("x-cache", Some("MISS-STORE-FAIL"));
                self.resume_http_response();
                Action::Continue
            }
        }
    } else {
        self.resume_http_response();
        Action::Continue
    }
}
```

### 7.8 Store response handler

```rust
fn on_store_response(&mut self, _: usize) {
    let _ = self.get_http_call_response_body(0, 0); // drain
    // Best-effort; never block client response on store outcome.
    self.resume_http_response();
}
```

---

## 8. Streaming Replay

### 8.1 Storage strategy (v1: canonical JSON)

Store the **non-streaming canonical JSON** of the upstream response (`stream_mode: "json"`).
On HIT, the filter reads the cached JSON and:
- If client asked `stream: false` → send the cached JSON as-is.
- If client asked `stream: true` → synthesize valid SSE frames in the guest:

```rust
fn synth_sse_from_json(&self, json_body: &[u8], chat_id: &str) -> Vec<u8> {
    // Build a synthetic OpenAI chat.completion.chunk stream:
    //   data: {"id":"<chat_id>","object":"chat.completion.chunk","choices":[{"delta":{"role":"assistant"},"index":0}]}\n\n
    //   data: {...delta content chunks...}\n\n
    //   data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n
    //   data: [DONE]\n\n
}
```

This avoids the entire class of "store streamed, replay malformed" bugs (vllm-project/
semantic-router #913). The client sees instantaneous synthetic streaming (zero
inter-chunk delay : for a cache HIT, the body is available instantly, so this is
functionally equivalent to an upstream stream).

### 8.2 v2 enhancement (preserve original SSE)

Store `stream_mode: "sse"` with the original SSE byte payload. On HIT replay the
original SSE bytes verbatim with `content-type: text/event-stream`. This preserves
first-token-timing realism for benchmarks. Default remains v1 (canonical JSON) for
operational simplicity.

```rust
fn frame_response(&self, stored_stream_mode: &str, request_body: &[u8], body: &[u8]) -> (String, Vec<u8>) {
    let client_stream = client_wants_stream(request_body);
    match (stored_stream_mode, client_stream) {
        ("json", false) => ("application/json".into(), body.to_vec()),
        ("json", true)  => ("text/event-stream".into(), self.synth_sse_from_json(body, &uuid::Uuid::new_v4().to_string())),
        ("sse",  false) => ("application/json".into(), self.parse_sse_to_json(body)),
        ("sse",  true)  => ("text/event-stream".into(), body.to_vec()),
    }
}
```

---

## 9. Plugin Ordering with Redaction (Critical)

On cache **HIT**, the redaction Lua plugin's `body_filter` MAY NOT run on the synthetic
`send_http_response` body in all Kong versions. To guarantee re-hydration regardless of
host behaviour:

- **Option A (recommended):** the cache filter re-hydrates inline using the cached
  `redact_key` (which the shim stored alongside the response). The shim's `redact_key`
  is the PII map Hash field from the original upstream-encoded response.
- **Option B:** use the `dispatch_http_call` to the redaction-engine's `/restore`
  endpoint. Adds a roundtrip per HIT; only justified if inline restoration is unsafe
  for some reason (e.g. placeholders span across synthesized SSE frames : but v1
  canonical-JSON storage makes them atomic).

The shim's `/cache/store` endpoint receives the **already-redacted-by-redact-Lua-plugin
response body** (the response from upstream has already been re-hydrated by the time
the cache fires its store; filter chain order must be `[auth → cache → redact → failover →
upstream]`). The PII-containing original is the original client-facing response, which
has been through `redact.body_filter`. The cache must store a **re-redacted-with-new-
placeholders** version OR the post-re-hydration original. Spec choice for v1:
**store the post-re-hydration original** (with placeholders replaced by real PII).
Then on HIT, before `send_http_response`, the cache filter MUST run redaction again on
the cached body (so the placeholder substitution is fresh per request : different user,
possibly different PII for same prompt). This is spec'd in detail in section 8 of the
redaction docs.

For v1 the spec accepts storing the placeholder-laden body (the **pre-re-hydration**
form). The cached response stored has placeholders (`[CUSTOMER_NAME_1]`); the
redact-native-plugin's re-hydration runs on the cache-replay path by stashing
`redact_key` for THIS stream on the cache HIT and letting downstream redact plugin
pick it up. The exact plumbing requires the redact Lua plugin to support "external PII
map injection via header" : documented in the redact plugin spec.

---

## 10. Implementation Skeleton

```
semantic-cache-filter/
  .cargo/config.toml                       # target = wasm32-wasip1
  Cargo.toml                                # proxy-wasm=0.2; serde-json-wasm; base64 for fp32 (encoded as JSON array to keep shim contract simple)
  semantic_cache_filter.meta.json           # config_schema above
  src/
    lib.rs                                   # proxy_wasm::main! + RootContext + HttpContext impls
    config.rs                                # deserialize Config; build once at on_configure
    embed.rs                                 # /embed dispatch + response parse + dim validate
    cache.rs                                 # /cache/query + /cache/store dispatch + parse
    output.rs                                # synth_sse_from_json, parse_sse_to_json, frame_response
    error.rs                                 # miss_with_header helpers
```

### JSON encoding for the vector

The shim accepts the vector as a JSON array of f64 (e.g. `[0.0123, -0.0456, ...]`).
The shim converts the JSON array to little-endian `FLOAT32` bytes internally before
`FT.SEARCH PARAMS`. **The guest never packs FP32.** This keeps the wasm filter small
(no float bit manipulation) at the cost of a 3072-element JSON array per call (well
under 24KB, fine for `dispatch_http_call`).

### SHM zone name

The filter uses one shared_data SHM zone for its own internal cache of last-N
embeddings (optional dedup-prevention). Zone name `sem_cache_dedup` : declare via
`KONG_NGINX_WASM_SHM_SEM_CACHE_DEDUP=4m`. Default off (config
`enable_dedup: false`).

---

## 11. Failure Modes (graceful MISS : NEVER fail closed)

A cache that fails *closed* (denying requests when Redis is down) is a
denial-of-service amplifier. Per AGENTS.md Rule 13 (no silent fallback), errors ARE
surfaced via response header + log/metric, but **the request ALWAYS proceeds to
upstream on MISS**, never blocked:

| Failure | Detection | Action |
|---------|-----------|--------|
| Tenant/tier header missing | header check in `on_http_request_headers` | **403** `missing_isolation_metadata` (THIS is fail-closed by design : security failure) |
| Embedding shim 5xx | `dispatch_http_call` returns Err OR 5xx response | log `cache.embed.failed`; MISS; emit `X-Cache: MISS-EMBED-FAIL` |
| Embedding timeout | `on_http_call_response` nh=0,bs=0 | same |
| Embedding wrong dim | `embed_resp.dim != config.embedding_dim` | log `cache.embed.dim-mismatch`; MISS; **never store wrong vector** (silent-garbage risk) |
| Cache `/cache/query` 5xx | non-2xx from shim | log `cache.query.failed`; MISS; `X-Cache: MISS-QUERY-FAIL` |
| Cache query timeout | nh=0,bs=0 | MISS |
| Threshold miss (`distance > threshold`) | shim returns `hit:false, distance, threshold` | normal MISS path → forward + store after response |
| `/cache/store` failure | non-2xx | log `cache.store.failed`; **don't retry**; `resume_http_response` (response already delivered to client) |
| Malformed request body (cjson decode fails) | parse failure in `on_http_request_body` | MISS → `resume_http_request` (let upstream validate) |
| `stop_on_failure: true` (deliberate closed-mode) | any of the above | on infra failure send 503 (NOT default). Production default is false. |

**`X-Cache: MISS-*`** headers are surfaced in the Kong audit log alongside `ai.proxy.usage
.*` so chargeback reconciliation distinguishes cache misses from upstream-called costs.

---

## 12. Test Plan (Required)

- Unit: `frame_response` matrix : (`json`, `sse`) × (`true`, `false`) client stream.
- Unit: `synth_sse_from_json` produces valid OpenAI `chat.completion.chunk` frames
  ending in `data: [DONE]\n\n`.
- Unit: dim-mismatch detection : random 1536-dim embed_resp → MISS +
  `X-Cache-Error: embed-dim-mismatch`, NEVER stored.
- Unit: missing-tenant → 403 (fail closed); missing-tier → 403.
- Integration: redisvl-backed shim; inject two prompts at cosine sim > 0.95 → second
  request returns cached body with `X-Cache: HIT`.
- Integration: two tenants with identical prompts → tenant-A HIT does not bleed to
  tenant-B (B always MISS for fresh prompt).
- Integration: kill redis → all subsequent requests MISS with `X-Cache: MISS-QUERY-FAIL`,
  NEVER 5xx to client; restore redis → cache resumes.
- Integration: stop_on_failure true → kill redis → 503 to client; verify it deliberately
  fails (per route opt-in).
- Integration: streaming replay : client `stream:true`, cached entry stored as JSON →
  receives valid SSE; first token delay is zero (instant, not inter-chunk).

---

## 13. Open Questions

| Q | Resolution |
|---|------------|
| Store post-re-hydration response or placeholder-laden response? | v1 stores **placeholder-laden** (pre-re-hydration); the redact Lua plugin re-hydrates on replay. Requires redact plugin "external PII map injection" hook. |
| Embedding model: OpenAI `text-embedding-3-large` vs local model | Default OpenAI; local model optional (`embedding_source: openai` \| `local`) |
| Shims one-combined or two-distinct? | v1 one combined shim (simpler deploy); split allowed via config |
| Per-tenant Redis instance (hard isolation) vs one shared instance + TAG filter | Default shared + TAG; per-tenant index opt-in via `index_name` in shim |
| Vector Sets (`VADD`/`VSIM`) vs RediSearch FT.* | Default FT.* (Redis 8); Vector Sets alternative tracked for v2 |

---

## 14. References

- Redis VSS FT.CREATE / FT.SEARCH + KNN: https://redis.io/docs/latest/develop/ai/search-and-query/vectors/
- HNSW attributes (M/EF_RUNTIME): https://docs.aws.amazon.com/memorydb/latest/devguide/vector-search-commands-ft.create.html
- Hybrid TAG + KNN pre-filter: https://redis.io/docs/latest/develop/ai/search-and-query/query/combined/
- Filter modes HYBRID_POLICY (ADHOC_BF): https://redis.io/docs/latest/develop/ai/search-and-query/query/vector-search/
- Redis 8 expiry behavior (RediSearch honours key TTL): https://redis.io/docs/latest/develop/ai/search-and-query/advanced-concepts/expiration/
- Per-tenant index aliases: https://redis.io/docs/latest/develop/ai/search-and-query/best-practices/index-mgmt-best-practices/
- `redisvl` `SemanticCache` (reference wrapper): https://redis.io/docs/latest/develop/ai/redisvl/user_guide/how_to_guides/llmcache/
- Kong `ai-semantic-cache` reference (`threshold` cosine distance semantics): https://developer.konghq.com/plugins/ai-semantic-cache/reference/
- Kong `ai-semantic-cache` OpenAI example: https://developer.konghq.com/plugins/ai-semantic-cache/examples/openai/
- Proxy-Wasm single `on_http_call_response` (no streaming): https://github.com/proxy-wasm/spec/blob/main/abi-versions/v0.2.1/README.md
- `dispatch_http_call` Hostname (not Envoy cluster): https://github.com/Kong/ngx_wasm_module/discussions/564
- vllm-project/semantic-router #913 (store-streamed replay malformed): https://github.com/vllm-project/semantic-router/issues/913
- `BerriAI/liteLLM` PR #24580 (CachedResponsesAPIStreamingIterator): https://github.com/BerriAI/litellm/pull/24580
- `GuglielmoCerri/khazad` (canonical JSON storage stream-both-ways): https://github.com/GuglielmoCerri/khazad

---

**End of document.**