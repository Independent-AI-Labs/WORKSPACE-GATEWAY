# SPEC-SEMANTIC-CACHE: Redis VSS Semantic Cache Plugin Implementation

**Date:** 2026-07-17
**Status:** Draft
**Type:** Specification
**Requirements:** [REQ-SEMANTIC-CACHE](../requirements/REQ-SEMANTIC-CACHE.md)

> Intended design of the `semantic-cache` APISIX Lua plugin and its Rust
> embedding sidecar. The plugin queries Redis 8 VSS directly over cosockets;
> there is no cache-adapter sidecar. Key invariants: per-tenant/per-tier TAG
> isolation, fail-open MISS semantics, canonical-JSON storage with SSE
> synthesis on replay. Nothing described here exists in the codebase yet.

---

**Cross-references:**
- [REQ-SEMANTIC-CACHE](../requirements/REQ-SEMANTIC-CACHE.md): requirements contract
- Legacy design absorbed into this document (v2, deferred)
- [`plugins/custom/redact.lua`](../../plugins/custom/redact.lua): existing plugin at priority 2500 (cache runs before it)
- [`conf/config.yaml`](../../conf/config.yaml): plugin registration point (semantic-cache absent)
- [`conf/apisix.yaml`](../../conf/apisix.yaml): route definitions (no semantic-cache routes)

---

## 1. Overview

A semantic cache for LLM chat completions: identical-meaning prompts within a
tenant/tier return the cached upstream response instead of re-calling the
provider. Embedding computation is delegated to a local Rust sidecar over an
OpenAI-compatible API; Redis VSS queries run inline in the APISIX worker via
`lua-resty-redis` cosockets. Storage happens off the request path in the `log`
phase via `ngx.timer.at`.

## 2. Architectural Principles

### 2.1 Fail open, never fail closed (except isolation)

All embedding/Redis failures degrade to MISS; the request proceeds upstream.
Only missing tenant/tier isolation metadata fails closed (403).

### 2.2 Tenant/tier isolation is structural

The TAG pre-filter is applied before KNN search; a tenant-B request can never
see tenant-A entries.

### 2.3 Canonical JSON storage

Store the non-streaming canonical JSON. SSE is synthesized on replay for
streaming clients.

### 2.4 No cache-adapter sidecar

The only sidecar is the Rust embedding service. Redis commands are plain
`FT.SEARCH`/`HSET`/`EXPIRE` over cosockets.

## 3. System Diagram

```
APISIX custom Lua plugin (semantic-cache)           Embedding Sidecar (Rust)
+-----------------------------------------+        +----------------------+
| access phase:                            |        | axum/hyper server    |
|   extract messages from request body     |  POST  | POST /v1/embeddings  |
|   call embedding sidecar (cosocket)      | -----> | torch or llama.cpp   |
|   query Redis VSS (FT.SEARCH, cosocket)  |        | local embedding model|
|   if HIT: synth response, return 200     | <----- | returns float[]      |
|   if MISS: stash embed+prompt in ctx     |        +----------------------+
| body_filter: buffer chunks on MISS       |
| log phase (ngx.timer.at):                |
|   HSET + EXPIRE canonical JSON           |
+-----------------------------------------+
                                           Redis 8 (VSS)
                                           +----------------------+
                                           | FT.SEARCH idx:semcache|
                                           | KNN + TAG pre-filter  |
                                           | (tenant, tier)        |
                                           +----------------------+
```

## 4. Plugin Manifest and Schema

| Property | Value |
|----------|-------|
| name | `semantic-cache` |
| version | 0.1 |
| priority | 2550 (after auth at 2599, before `redact` at 2500) |

| Schema property | Type | Default | Purpose |
|-----------------|------|---------|---------|
| `embedding_url` | string (required) |  -  | Sidecar embeddings endpoint |
| `embedding_model` | string | `bge-large-en-v1.5` | Model name sent to sidecar |
| `embedding_dim` | integer | 1024 | Expected vector dimension |
| `redis_host` | string | `127.0.0.1` | Redis host |
| `redis_port` | integer | 6379 | Redis port |
| `redis_db` | integer | 0 | Redis DB index |
| `distance_threshold` | number | 0.10 | Cosine distance [0-2]; 0.10 ~ 0.90 similarity |
| `cache_ttl_seconds` | integer | 300 | Entry TTL |
| `timeout_ms` | integer | 2000 | Cosocket timeout |
| `message_countback` | integer | 1 | Trailing messages used for prompt text |
| `ignore_system_prompts` | boolean | true | Skip system role messages |
| `stop_on_failure` | boolean | false | Opt-in 503 on infra failure |

## 5. Access Phase Algorithm

1. Read `x-tenant-id` / `x-routing-tier`; missing or empty -> 403
   `missing_isolation_metadata`.
2. Read and JSON-parse the request body; require `messages`.
3. Extract prompt text (trailing N messages, system skipped per config).
4. POST `{model, input}` to `embedding_url` via `resty.http` cosocket.
   Non-200 or unreachable -> `ctx.cache_status = "MISS-EMBED-FAIL"`, proceed.
5. Validate `data[1].embedding` exists and `#vector == embedding_dim`;
   otherwise MISS (`MISS-EMBED-MALFORMED` / `MISS-EMBED-DIM-MISMATCH`).
6. Pack the vector as a little-endian float32 binary blob via `ffi`.
7. Run hybrid query over `resty.redis` cosocket:

```
FT.SEARCH idx:semcache
  "(@tenant:{tenant} @tier:{tier})=>[KNN 1 @embedding $qvec AS distance]"
  PARAMS 2 qvec <blob> LIMIT 0 1
  RETURN 5 distance response stream_mode format DIALECT 2
```

8. Parse the RESP3 array reply. On hit with `distance <= distance_threshold`,
   frame the response per §7 and return 200 with `X-Cache: HIT`. On miss,
   stash `{vector, prompt, tenant, tier, stream, request_body}` in `ctx`.

## 6. Body Filter and Log Phase

- `body_filter`: if `ctx.cache_miss`, append `ngx.arg[1]` to
  `ctx.cache_response_buffer` without modifying the chunk stream.
- Canonicalization: SSE frames are parsed (`data: {...}\n\n` up to
  `data: [DONE]`), delta contents concatenated, and re-encoded as
  `{"choices":[{"message":{"role":"assistant","content":"..."}}]}`.
- `log`: if `ctx.cache_miss` and a captured buffer exists, canonicalize and
  store off-thread via `ngx.timer.at`:

```
HSET semcache:{tenant}:{tier}:{uuid}
  embedding <blob>  prompt <text>  response <canonical json>
  stream_mode sse|json  format openai  tenant <t>  tier <r>
EXPIRE semcache:{tenant}:{tier}:{uuid} <cache_ttl_seconds>
```

Store failure: log and drop; never retry.

## 7. Streaming Replay

| Stored mode | Client `stream` | Result |
|-------------|-----------------|--------|
| json | false | `application/json`, body as-is |
| json | true | `text/event-stream`, synthesized SSE |
| sse | false | `application/json`, parsed to canonical JSON |
| sse | true | `text/event-stream`, body as-is |

SSE synthesis from JSON: initial role delta frame, per-word content frames,
final frame with `finish_reason: "stop"`, then `data: [DONE]\n\n`.

## 8. Embedding Sidecar Contract (Rust)

### 8.1 `POST /v1/embeddings`

Request: `{"model": "bge-large-en-v1.5", "input": "<prompt text>"}`

Response (200):

```json
{
  "data": [{ "embedding": [0.0123, -0.0456], "index": 0 }],
  "model": "bge-large-en-v1.5",
  "usage": { "prompt_tokens": 8, "total_tokens": 8 }
}
```

### 8.2 `GET /healthz`

```json
{"status":"ok","model":"bge-large-en-v1.5","dim":1024,"uptime_secs":12345}
```

### 8.3 Implementation notes

| Property | Value |
|----------|-------|
| Runtime | Rust, axum/hyper on tokio |
| Inference | torch (libtorch) or llama.cpp bindings |
| Threading | `tokio::task::spawn_blocking` for CPU-bound inference |
| Model lifecycle | loaded once at startup, shared via `Arc` |
| Listen address | `127.0.0.1:8090` (same host as APISIX) |

## 9. Redis VSS Schema

```
FT.CREATE idx:semcache ON HASH PREFIX 1 semcache:
  SCHEMA
    tenant TAG  tier TAG  prompt TEXT  response TEXT
    embedding VECTOR HNSW 6
      TYPE FLOAT32 DIM 1024 DISTANCE_METRIC COSINE
      M 16 EF_CONSTRUCTION 200 EF_RUNTIME 10
```

COSINE distance range `[0, 2]`; 0 = identical. Default threshold 0.10 equals
cosine similarity >= 0.90. The TAG pre-filter runs before KNN, so isolation
is enforced inside Redis, not in Lua.

## 10. Failure Modes

| Failure | Detection | Action |
|---------|-----------|--------|
| Tenant/tier header missing | header check | 403 (fail closed) |
| Embedding sidecar 5xx/unreachable/timeout | httpc nil or 5xx | MISS, `X-Cache: MISS-EMBED-FAIL` |
| Embedding wrong dim | `#vector != embedding_dim` | MISS, never store |
| Redis connect/query failure or timeout | red nil | MISS, `X-Cache: MISS-QUERY-FAIL` |
| Distance above threshold | `hit.distance > threshold` | normal MISS, forward + store |
| Store failure in log phase | red nil | log, no retry |
| `stop_on_failure: true` | any of above | 503 (per-route opt-in only) |

## 11. Edge Cases & Decisions

- **Streaming client, JSON-stored entry:** synthesize SSE; do not store SSE.
- **Store post-re-hydration:** canonical JSON stored after the redact plugin's
  re-hydration; `redact` re-runs on cached HITs.
- **Binary PARAMS in `do_raw`:** float32 blob packed via `ffi`; verify
  `lua-resty-redis` binary handling at implementation time.
- **No request on cache hit reaches upstream:** cost/usage plugins
  (`sse-usage`, `cost_calc`) see no tokens for HITs; acceptable by design.

## 12. File Map

| File | Purpose | Key Changes |
|------|---------|-------------|
| `plugins/custom/semantic-cache.lua` (planned) | Plugin: access/body_filter/log | new file |
| embedding sidecar crate (planned) | `POST /v1/embeddings`, `GET /healthz` | new Rust binary |
| `conf/config.yaml` (planned edit) | register `semantic-cache` in `plugins:` | add entry |
| `conf/apisix.yaml` (planned edit) | per-route plugin config | add plugin block to relay routes |

## 13. Implementation Status

| Component | Status | Evidence |
|-----------|--------|----------|
| `plugins/custom/semantic-cache.lua` | Not implemented | file does not exist; grep `semantic` in `plugins/custom/` returns no match |
| Plugin registration | Not implemented | `conf/config.yaml` `plugins:` list contains no `semantic-cache` |
| Route configuration | Not implemented | `conf/apisix.yaml` contains no `semantic-cache` reference |
| Rust embedding sidecar | Not implemented | no `Cargo.toml`/Rust sources in repo; no sidecar service in deployment configs |
| Redis VSS index bootstrap | Not implemented | no `FT.CREATE`/`idx:semcache` anywhere in `conf/`, `res/`, or `tests/` |
| Tests | Not implemented | no `tests/**` referencing semantic cache |
