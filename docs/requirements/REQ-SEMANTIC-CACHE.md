# REQ-SEMANTIC-CACHE: pgvector Semantic Cache Plugin

**Date:** 2026-09-23
**Status:** Draft
**Type:** Requirements
**Specification:** [SPEC-SEMANTIC-CACHE](../specifications/SPEC-SEMANTIC-CACHE.md)

> This document mandates the intended design of a pure-Lua APISIX plugin
> (`semantic-cache`) that caches LLM chat completions using PostgreSQL +
> pgvector similarity search with per-tenant/per-tier isolation, delegating
> embedding computation to a local `llama-server` (llama.cpp) over an
> OpenAI-compatible `/v1/embeddings` API. The cache runs at priority 2450,
> after `redact` 2500, so it embeds the redacted prompt and stores the
> tokenized response. The cache MUST treat every infrastructure error as a
> MISS and proceed upstream, logging the error. This feature is a deferred v2
> design: nothing in this document is implemented in the current codebase.

---

**Cross-references:**
- [SPEC-SEMANTIC-CACHE](../specifications/SPEC-SEMANTIC-CACHE.md): companion specification
- [REQ-REDACT](../requirements/REQ-REDACT.md) / [SPEC-REDACT](../specifications/SPEC-REDACT.md): redaction pipeline the cache composes with (C-4)
- [`plugins/custom/redact.lua`](../../plugins/custom/redact.lua): existing plugin whose priority ordering (2500) the cache design references
- [ADR-001](../proposals/ADR-001-APISIX-PIVOT.md): APISIX pivot that first scoped `semantic-cache` as a custom Lua plugin

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
- The local llama.cpp embedding service contract (`POST /v1/embeddings`,
  `GET /health`) and its GGUF model profiles
- The pgvector schema (`semantic_cache_<profile>_<dim>`) and filtered HNSW query
- Streaming replay (canonical JSON storage, SSE synthesis)
- Failure-mode semantics (fail open, `X-Cache` status headers)

**This document DOES NOT:**
- Replace or modify exact-match caching, rate limiting, or redaction requirements
- Cover the `redact` plugin (see REQ-REDACT / implemented Lua plugin)
- Cover any cache-adapter sidecar (explicitly excluded: the plugin queries
  pgvector directly via `pgmoon`)

### 1.3 Terminology

| Term | Definition |
|------|------------|
| pgvector | PostgreSQL `vector` extension; HNSW index, `halfvec`, cosine operator `<=>` |
| HIT | Cache lookup returned a response within `distance_threshold` |
| MISS | Cache lookup failed or found nothing; request proceeds to upstream |
| Canonical JSON | Non-streaming OpenAI `chat.completion` JSON derived from any response shape |
| Tenant / Tier | Isolation headers `x-tenant-id` / `x-routing-tier` injected by auth plugins |
| Embedding service | Local `llama-server` (llama.cpp) producing float32 embedding vectors, OpenAI contract |
| Profile | Named embedding namespace (`quality` 1024d / `latency` 640d); spaces are incompatible |

## 2. Functional Requirements

### FR-1: Cache Lookup

| ID | Requirement |
|----|-------------|
| FR-1.1 | The plugin MUST run in the `access` phase at priority 2450 (after `redact` at 2500 and before `sse-usage` at 2400), so it embeds the redacted prompt. |
| FR-1.2 | The plugin MUST reject requests missing `x-tenant-id` or `x-routing-tier` with 403 `missing_isolation_metadata` (fail closed, security invariant). |
| FR-1.3 | The plugin MUST extract prompt text from the trailing N request messages (`message_countback`, default 1) and MUST skip system prompts when `ignore_system_prompts` is true (default). |
| FR-1.4 | The plugin MUST prefix the embedded prompt with the configured `query_prefix` (the model's task instruction) and MUST obtain an embedding by POSTing `{model, input}` to the configured `embedding_url` via a non-blocking cosocket (`lua-resty-http`). |
| FR-1.5 | The plugin MUST treat a vector whose dimension does not equal `embedding_dim` as a MISS and MUST NOT store it. |
| FR-1.6 | The plugin MUST query pgvector over a `pgmoon` cosocket with a `WHERE tenant_id = $1 AND tier = $2 AND expires_at > now()` predicate before the HNSW ordering, so cross-tenant cache bleed is impossible. |
| FR-1.7 | The query MUST enable pgvector iterative index scanning (`hnsw.iterative_scan = relaxed_order`) so filtered searches preserve recall. |
| FR-1.8 | A HIT (returned cosine distance <= `distance_threshold`, default 0.10) MUST short-circuit with HTTP 200, the cached body, and header `X-Cache: HIT`, with no upstream call. |
| FR-1.9 | On MISS the plugin MUST stash the vector, prompt, tenant, tier, stream flag, and request body in `ctx` for the log-phase store. |

### FR-2: Response Capture and Store

| ID | Requirement |
|----|-------------|
| FR-2.1 | On MISS, `body_filter` MUST passively buffer upstream response chunks without modifying them. |
| FR-2.2 | The plugin MUST convert streaming (SSE) upstream responses to canonical non-streaming JSON before storage. |
| FR-2.3 | The plugin MUST store entries in the `log` phase via `ngx.timer.at` (off the request path) as a parameterized `INSERT` of `embedding`, `prompt`, `response`, `stream_mode`, `format`, `tenant_id`, `tier`, `expires_at` (`now() + cache_ttl_seconds`). |
| FR-2.4 | The stored `response` and `prompt` MUST be the post-redaction (tokenized) values; PII MUST NOT be stored. |
| FR-2.5 | Store failures MUST be logged and MUST NOT be retried or surfaced to the client. |
| FR-2.6 | Expired rows MUST be removed by a periodic `DELETE ... WHERE expires_at < now()` job; the read path MUST also filter on `expires_at`. |

### FR-3: Streaming Replay

| ID | Requirement |
|----|-------------|
| FR-3.1 | The plugin MUST store canonical JSON as the default storage format. |
| FR-3.2 | On HIT with a streaming client (`stream: true`) and JSON-stored entry, the plugin MUST synthesize valid OpenAI `chat.completion.chunk` SSE frames ending in `data: [DONE]\n\n`. |
| FR-3.3 | On HIT with a non-streaming client, the plugin MUST return `application/json` with the canonical body. |
| FR-3.4 | The plugin MUST replay stored response tokens unchanged and rely on `redact.body_filter` to rehydrate them for the client. |

### FR-4: Embedding Service

| ID | Requirement |
|----|-------------|
| FR-4.1 | The service MUST expose `POST /v1/embeddings` accepting `{model, input}` and returning the OpenAI embeddings response shape. |
| FR-4.2 | The service MUST expose `GET /health` returning service status. |
| FR-4.3 | The service MUST be stock `llama-server` (llama.cpp) running a GGUF, with no hand-written inference sidecar; the model is loaded once at startup. |
| FR-4.4 | The service MUST run locally on the internal network and MUST NOT call external embedding APIs. |
| FR-4.5 | The service MUST offer a `quality` profile (`harrier-oss-v1-0.6b`, 1024d) and a `latency` profile (`harrier-oss-v1-270m`, 640d), both MIT, both last-token pooling. |
| FR-4.6 | The GGUF MUST be a conversion verified against the HuggingFace reference (golden-vector cosine) and MUST include any SentenceTransformer dense modules; pooling must match the model. |
| FR-4.7 | The plugin MUST consume only the `/v1/embeddings` contract, so a faster backend (ONNX Runtime / OpenVINO / CTranslate2 / TEI) MAY replace llama.cpp without plugin changes. |

### FR-5: pgvector Schema

| ID | Requirement |
|----|-------------|
| FR-5.1 | The database MUST have the `vector` extension; each profile MUST have its own table `semantic_cache_<profile>_<dim>` with columns `id`, `embedding halfvec(DIM)`, `prompt`, `response`, `stream_mode`, `format`, `tenant_id`, `tier`, `expires_at`. |
| FR-5.2 | Each table MUST have an HNSW index using `halfvec_cosine_ops` (`m = 16`, `ef_construction = 200`) and a `(tenant_id, tier, expires_at)` index. |
| FR-5.3 | Distance semantics MUST follow cosine `[0, 2]`; threshold 0.10 corresponds to cosine similarity >= 0.90. |
| FR-5.4 | The cache role MUST be least-privilege and own only the cache tables. |

## 3. Non-Functional Requirements

| ID | Requirement |
|----|-------------|
| NFR-1.1 | The plugin MUST fail open on embedding-service errors, PostgreSQL errors, and timeouts: the request always proceeds to upstream on MISS. |
| NFR-1.2 | `stop_on_failure: true` MAY be offered as a per-route opt-in returning 503; it MUST NOT be the default. |
| NFR-1.3 | All cache operations MUST use cosockets or `ngx.timer.at`; the nginx worker MUST NOT block. |
| NFR-1.4 | MISS reasons MUST be observable via `X-Cache` header values (`MISS-EMBED-FAIL`, `MISS-EMBED-MALFORMED`, `MISS-EMBED-DIM-MISMATCH`, `MISS-QUERY-FAIL`). |
| NFR-1.5 | The embedding model MUST be configurable and MUST exist only in GGUF form under the llama.cpp service. |
| NFR-1.6 | PostgreSQL and the embedding service MUST NOT publish host ports; both MUST live on an internal-only network with secrets from OpenBao/.env. |
| NFR-1.7 | The embedding model and quant MUST be selected by a local benchmark gate (golden-vector cosine vs reference, recall@k on real prompts, p50/p95 latency, llama.cpp vs ONNX), not by public leaderboard alone. |

## 4. Constraints

| ID | Constraint | Source |
|----|------------|--------|
| C-1 | No cache-adapter sidecar; pgvector is queried with parameterized SQL via `pgmoon` | earlier semantic-cache spec §1 |
| C-2 | The only auxiliary service is the llama.cpp embedding endpoint | earlier semantic-cache spec §9 |
| C-3 | Missing tenant/tier is a security failure and fails closed (403) | earlier semantic-cache spec §10 |
| C-4 | The cache runs after `redact`; it embeds the tokenized prompt and stores the tokenized response; `redact` rehydrates on every response path including HITs | earlier semantic-cache spec §12, revised |
| C-5 | `quality` and `latency` profiles are separate namespaces; cross-profile lookup is forbidden | SPEC §8.4 |

## 5. Assumptions

| ID | Assumption |
|----|------------|
| A-1 | PostgreSQL 17 with pgvector 0.8 (`halfvec`, HNSW, iterative scan) is available at cache deploy time. |
| A-2 | Auth plugins inject `x-tenant-id` / `x-routing-tier` before priority 2450, and `redact` at 2500 runs before the cache. |
| A-3 | `pgmoon` correctly parameterizes pgvector literals and `halfvec` casts over the text protocol. |

## 6. Open Questions

| Q | Resolution |
|---|------------|
| Embedding model choice | Dual `harrier-oss-v1` profiles: `quality` 0.6b (1024d), `latency` 270m (640d); both MIT |
| llama.cpp vs ONNX as backend | llama.cpp default; ONNX/TEI permitted via the `/v1/embeddings` seam if the REQ §3 NFR-1.7 benchmark favors them |
| Per-tenant table/index vs shared + predicate | Default shared table with `(tenant_id, tier)` predicate + iterative scan; partitioning opt-in |
| Quant | Q8_0 default (near-lossless); Q6_K if footprint matters |

## 7. Verification Matrix

| # | Test | Maps to |
|---|------|---------|
| V1 | Unit: vector literal formatting for pgvector `halfvec` cast | FR-1.6 |
| V2 | Unit: dim-mismatch yields MISS and never stores | FR-1.5 |
| V3 | Unit: missing tenant/tier yields 403 | FR-1.2 |
| V4 | Unit: SSE synthesis produces valid chunk frames + `[DONE]` | FR-3.2 |
| V5 | Integration: cosine sim > 0.90 prompt pair returns `X-Cache: HIT` | FR-1.8 |
| V6 | Integration: tenant A HIT never bleeds to tenant B | FR-1.6 |
| V7 | Integration: PostgreSQL down yields all-MISS, never 5xx | NFR-1.1 |
| V8 | Integration: streaming client receives valid SSE from JSON-stored entry | FR-3.2 |
| V9 | Integration: `stop_on_failure: true` + PostgreSQL down yields 503 | NFR-1.2 |
| V10 | Deploy gate: golden-vector cosine vs reference within tolerance | FR-4.6 |

## 8. Implementation Status

| Item | Status | Evidence |
|------|--------|----------|
| FR-1.1 semantic-cache plugin manifest | Not implemented | no `plugins/custom/semantic-cache.lua` in codebase |
| FR-1.2-FR-1.9 access phase | Not implemented | no `plugins/custom/semantic-cache.lua`; plugin absent from `plugins:` list in `conf/config.yaml` |
| FR-2.1-FR-2.6 body_filter / log store | Not implemented | no `plugins/custom/semantic-cache.lua` in codebase |
| FR-3.1-FR-3.4 streaming replay | Not implemented | no `plugins/custom/semantic-cache.lua` in codebase |
| FR-4.1-FR-4.7 llama.cpp embedding service | Not implemented | no `llama-server` service or GGUF in codebase |
| FR-5.1-FR-5.4 pgvector schema | Not implemented | no `CREATE EXTENSION vector`/`semantic_cache` DDL in `conf/` or `res/`; no PostgreSQL service in deployment config |
| NFR-1.x failure semantics | Not implemented | no plugin code; no `X-Cache` references in codebase |
| Routes using semantic-cache | Not implemented | `conf/apisix.yaml` contains no `semantic-cache` plugin reference |
