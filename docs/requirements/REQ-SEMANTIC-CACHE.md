# REQ-SEMANTIC-CACHE: Redis VSS Semantic Cache Plugin

**Date:** 2026-07-17
**Status:** Draft
**Type:** Requirements
**Specification:** [SPEC-SEMANTIC-CACHE](../specifications/SPEC-SEMANTIC-CACHE.md)

> This document mandates the intended design of a pure-Lua APISIX plugin
> (`semantic-cache`) that caches LLM chat completions using Redis 8 Vector
> Similarity Search (VSS) with per-tenant/per-tier TAG isolation, delegating
> embedding computation to a Rust sidecar over an OpenAI-compatible
> `/v1/embeddings` API. The cache MUST fail open (graceful MISS) on all
> infrastructure errors. This feature is a deferred v2 design: nothing in this
> document is implemented in the current codebase.

---

**Cross-references:**
- [SPEC-SEMANTIC-CACHE](../specifications/SPEC-SEMANTIC-CACHE.md): companion specification
- Legacy PLUGIN-SEMANTIC-CACHE design (AMI-PROP-LLMGW-PLUGIN-SEMANTIC-CACHE-v2.0, absorbed)
- [`plugins/custom/redact.lua`](../../plugins/custom/redact.lua): existing plugin whose priority ordering (2500) the cache design references

---

## 1. Purpose & Scope

### 1.1 Purpose

Define the requirements for a semantic cache that returns previously computed
LLM responses for semantically equivalent prompts (cosine similarity >= 0.90
by default), reducing upstream cost and latency, without ever blocking or
failing client requests when cache infrastructure is unavailable.

### 1.2 Scope

**This document OWNS the requirements for:**
- The `semantic-cache` APISIX Lua plugin (access / body_filter / log phases)
- The Rust embedding sidecar contract (`POST /v1/embeddings`, `GET /healthz`)
- The Redis VSS index schema (`idx:semcache`) and hybrid TAG + KNN query
- Streaming replay (canonical JSON storage, SSE synthesis)
- Failure-mode semantics (fail open, `X-Cache` status headers)

**This document DOES NOT:**
- Replace or modify exact-match caching, rate limiting, or redaction requirements
- Cover the `redact` plugin (see REQ-REDACT / implemented Lua plugin)
- Cover any cache-adapter sidecar (explicitly excluded: the plugin queries
  Redis VSS directly via `lua-resty-redis`)

### 1.3 Terminology

| Term | Definition |
|------|------------|
| VSS | Redis Vector Similarity Search (`FT.SEARCH` with KNN) |
| HIT | Cache lookup returned a response within `distance_threshold` |
| MISS | Cache lookup failed or found nothing; request proceeds to upstream |
| Canonical JSON | Non-streaming OpenAI `chat.completion` JSON derived from any response shape |
| Tenant / Tier | Isolation headers `x-tenant-id` / `x-routing-tier` injected by auth plugins |
| Embedding sidecar | Rust HTTP service producing float32 embedding vectors locally |

## 2. Functional Requirements

### FR-1: Cache Lookup

| ID | Requirement |
|----|-------------|
| FR-1.1 | The plugin MUST run in the `access` phase at priority 2550 (after auth plugins, before `redact` at 2500). |
| FR-1.2 | The plugin MUST reject requests missing `x-tenant-id` or `x-routing-tier` with 403 `missing_isolation_metadata` (fail closed, security invariant). |
| FR-1.3 | The plugin MUST extract prompt text from the trailing N request messages (`message_countback`, default 1) and MUST skip system prompts when `ignore_system_prompts` is true (default). |
| FR-1.4 | The plugin MUST obtain an embedding vector by POSTing `{model, input}` to the configured `embedding_url` via a non-blocking cosocket (`lua-resty-http`). |
| FR-1.5 | The plugin MUST treat a vector whose dimension does not equal `embedding_dim` as a MISS and MUST NOT store it. |
| FR-1.6 | The plugin MUST query Redis with a hybrid TAG + KNN pre-filter `(@tenant:{t} @tier:{r})=>[KNN 1 @embedding $qvec AS distance]`, so cross-tenant cache bleed is impossible. |
| FR-1.7 | A HIT (returned cosine distance <= `distance_threshold`, default 0.10) MUST short-circuit with HTTP 200, the cached response body, and header `X-Cache: HIT`, with no upstream call. |
| FR-1.8 | On MISS the plugin MUST stash the vector, prompt, tenant, tier, stream flag, and request body in `ctx` for the log-phase store. |

### FR-2: Response Capture and Store

| ID | Requirement |
|----|-------------|
| FR-2.1 | On MISS, `body_filter` MUST passively buffer upstream response chunks without modifying them. |
| FR-2.2 | The plugin MUST convert streaming (SSE) upstream responses to canonical non-streaming JSON before storage. |
| FR-2.3 | The plugin MUST store entries in the `log` phase via `ngx.timer.at` (off the request path) using `HSET` fields `embedding`, `prompt`, `response`, `stream_mode`, `format`, `tenant`, `tier` under key `semcache:{tenant}:{tier}:{uuid}`, followed by `EXPIRE` with `cache_ttl_seconds` (default 300). |
| FR-2.4 | Store failures MUST be logged and MUST NOT be retried or surfaced to the client. |

### FR-3: Streaming Replay

| ID | Requirement |
|----|-------------|
| FR-3.1 | The plugin MUST store canonical JSON as the default storage format. |
| FR-3.2 | On HIT with a streaming client (`stream: true`) and JSON-stored entry, the plugin MUST synthesize valid OpenAI `chat.completion.chunk` SSE frames ending in `data: [DONE]\n\n`. |
| FR-3.3 | On HIT with a non-streaming client, the plugin MUST return `application/json` with the canonical body. |

### FR-4: Embedding Sidecar

| ID | Requirement |
|----|-------------|
| FR-4.1 | The sidecar MUST expose `POST /v1/embeddings` accepting `{model, input}` and returning the OpenAI embeddings response shape. |
| FR-4.2 | The sidecar MUST expose `GET /healthz` returning status, model name, dimension, and uptime. |
| FR-4.3 | The sidecar MUST run inference locally (torch or llama.cpp bindings) on `tokio::task::spawn_blocking` threads, with the model loaded once at startup and shared via `Arc`. |
| FR-4.4 | The sidecar SHOULD listen on `127.0.0.1` (same host as APISIX); it MUST NOT call external embedding APIs. |

### FR-5: Redis VSS Schema

| ID | Requirement |
|----|-------------|
| FR-5.1 | The index `idx:semcache` MUST be created on HASH with prefix `semcache:` and schema fields `tenant TAG`, `tier TAG`, `prompt TEXT`, `response TEXT`, `embedding VECTOR HNSW` (FLOAT32, DIM 1024 default, COSINE distance, M 16, EF_CONSTRUCTION 200, EF_RUNTIME 10). |
| FR-5.2 | Distance semantics MUST follow Redis COSINE `[0, 2]`; threshold 0.10 corresponds to cosine similarity >= 0.90. |

## 3. Non-Functional Requirements

| ID | Requirement |
|----|-------------|
| NFR-1.1 | The plugin MUST fail open on embedding sidecar errors, Redis errors, and timeouts: the request always proceeds to upstream on MISS. |
| NFR-1.2 | `stop_on_failure: true` MAY be offered as a per-route opt-in returning 503; it MUST NOT be the default. |
| NFR-1.3 | All cache operations MUST use cosockets or `ngx.timer.at`; the nginx worker MUST NOT block. |
| NFR-1.4 | MISS reasons MUST be observable via `X-Cache` header values (`MISS-EMBED-FAIL`, `MISS-EMBED-MALFORMED`, `MISS-EMBED-DIM-MISMATCH`, `MISS-QUERY-FAIL`). |
| NFR-1.5 | The default embedding model SHOULD be `bge-large-en-v1.5` (1024 dim, Apache 2.0) and MUST be configurable. |

## 4. Constraints

| ID | Constraint | Source |
|----|------------|--------|
| C-1 | No cache-adapter sidecar; Redis VSS queries are plain Redis commands via `lua-resty-redis` | legacy semantic-cache spec §1 |
| C-2 | Only Lua-sidecar is the Rust embedding service | legacy semantic-cache spec §9 |
| C-3 | Missing tenant/tier is a security failure and fails closed (403) | legacy semantic-cache spec §10 |
| C-4 | Cached responses are stored post-re-hydration; the `redact` plugin re-runs on cached HIT | legacy semantic-cache spec §12 |

## 5. Assumptions

| ID | Assumption |
|----|------------|
| A-1 | Redis 8 with RediSearch VSS (`FT.CREATE`/`FT.SEARCH` DIALECT 2) is available at cache deploy time. |
| A-2 | Auth plugins inject `x-tenant-id` / `x-routing-tier` before priority 2550. |
| A-3 | `lua-resty-redis` `do_raw` correctly handles binary float32 blobs in `PARAMS`. |

## 6. Open Questions

| Q | Resolution |
|---|------------|
| Embedding model choice | Default `bge-large-en-v1.5`; configurable |
| Per-tenant Redis index vs shared + TAG filter | Default shared + TAG; per-tenant index opt-in |
| Vector Sets (`VADD`/`VSIM`) vs RediSearch `FT.*` | Default `FT.*` (Redis 8); Vector Sets tracked as alternative |

## 7. Verification Matrix

| # | Test | Maps to |
|---|------|---------|
| V1 | Unit: `pack_vector` produces correct float32 binary blob | FR-1.6 |
| V2 | Unit: dim-mismatch yields MISS and never stores | FR-1.5 |
| V3 | Unit: missing tenant/tier yields 403 | FR-1.2 |
| V4 | Unit: SSE synthesis produces valid chunk frames + `[DONE]` | FR-3.2 |
| V5 | Integration: cosine sim > 0.90 prompt pair returns `X-Cache: HIT` | FR-1.7 |
| V6 | Integration: tenant A HIT never bleeds to tenant B | FR-1.6 |
| V7 | Integration: Redis down yields all-MISS, never 5xx | NFR-1.1 |
| V8 | Integration: streaming client receives valid SSE from JSON-stored entry | FR-3.2 |
| V9 | Integration: `stop_on_failure: true` + Redis down yields 503 | NFR-1.2 |

## 8. Implementation Status

| Item | Status | Evidence |
|------|--------|----------|
| FR-1.1 semantic-cache plugin manifest | Not implemented | no `plugins/custom/semantic-cache.lua` in codebase |
| FR-1.2-FR-1.8 access phase | Not implemented | no `plugins/custom/semantic-cache.lua`; plugin absent from `plugins:` list in `conf/config.yaml` |
| FR-2.1-FR-2.4 body_filter / log store | Not implemented | no `plugins/custom/semantic-cache.lua` in codebase |
| FR-3.1-FR-3.3 streaming replay | Not implemented | no `plugins/custom/semantic-cache.lua` in codebase |
| FR-4.1-FR-4.4 Rust embedding sidecar | Not implemented | no Rust crate, `Cargo.toml`, or embedding service in codebase (grep for `embeddings`/`ner-engine` in repo: no match) |
| FR-5.1-FR-5.2 Redis VSS index | Not implemented | no `FT.CREATE`/`idx:semcache` in `conf/` or `res/`; no Redis service in deployment config |
| NFR-1.x failure semantics | Not implemented | no plugin code; no `X-Cache` references in codebase |
| Routes using semantic-cache | Not implemented | `conf/apisix.yaml` contains no `semantic-cache` plugin reference |
