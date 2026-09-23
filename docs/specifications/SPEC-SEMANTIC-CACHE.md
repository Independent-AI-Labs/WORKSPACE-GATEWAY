# SPEC-SEMANTIC-CACHE: pgvector Semantic Cache Plugin Implementation

**Date:** 2026-09-23
**Status:** Draft
**Type:** Specification
**Requirements:** [REQ-SEMANTIC-CACHE](../requirements/REQ-SEMANTIC-CACHE.md)

> Intended design of the `semantic-cache` APISIX Lua plugin, its local
> llama.cpp embedding service, and its pgvector primary store. The plugin
> queries PostgreSQL + pgvector directly over `pgmoon` cosockets; there is no
> cache-adapter sidecar and no Redis. Embedding runs against a local
> `llama-server` over the OpenAI `/v1/embeddings` contract; the model is a
> `harrier-oss-v1` GGUF (dual quality/latency profiles). The cache runs at
> priority 2450, *after* `redact` 2500, so it embeds the redacted prompt and
> stores the tokenized response: no PII is sent to the embedding service and
> no PII is stored at rest. Nothing described here exists in the codebase yet.

---

**Cross-references:**
- [REQ-SEMANTIC-CACHE](../requirements/REQ-SEMANTIC-CACHE.md): requirements contract
- [REQ-REDACT](../requirements/REQ-REDACT.md) / [SPEC-REDACT](SPEC-REDACT.md): redaction pipeline the cache composes with (C-4)
- [`plugins/custom/redact.lua`](../../plugins/custom/redact.lua): existing plugin at priority 2500; cache runs immediately after it
- [`plugins/custom/sse-usage.lua`](../../plugins/custom/sse-usage.lua): reference pattern for cosocket HTTP + `ngx.timer.at` off-thread work
- [`conf/config.yaml`](../../conf/config.yaml): plugin registration point (semantic-cache absent)
- [`conf/apisix.yaml`](../../conf/apisix.yaml): route definitions (no semantic-cache routes)
- [`conf/sql`](../../conf/sql): SQL template tree (`res/scripts/lib-sql.sh` renders `{{ }}` templates)

---

## 1. Overview

A semantic cache for LLM chat completions: identical-meaning prompts within a
tenant/tier return the cached upstream response instead of re-calling the
provider. Embedding computation is delegated to a local `llama-server`
(llama.cpp) over an OpenAI-compatible `/v1/embeddings` API; vector search runs
inline in the APISIX worker via `pgmoon` cosockets against PostgreSQL with the
pgvector extension. Storage happens off the request path in the `log` phase via
`ngx.timer.at`.

The cache is ordered **after** the `redact` plugin. `redact` tokenizes the
request in place, then `semantic-cache` embeds the already-tokenized prompt and
stores the tokenized upstream response. On a HIT, `redact`'s
`header_filter`/`body_filter` rehydrate the tokens for the client as usual.

## 2. Architectural Principles

### 2.1 Fail open, never fail closed (except isolation)

All embedding/PostgreSQL failures are treated as MISS: the request proceeds
upstream and the failure is logged.
Only missing tenant/tier isolation metadata fails closed (403).

### 2.2 Tenant/tier isolation is structural

The tenant/tier predicate is applied inside the SQL `WHERE` before the HNSW
ordering; a tenant-B request can never see tenant-A rows. Filtered recall is
preserved with pgvector iterative index scans (§9.3).

### 2.3 Canonical JSON storage

Store the non-streaming canonical JSON. SSE is synthesized on replay for
streaming clients.

### 2.4 Tokenized at rest (PII boundary)

Because the plugin runs after `redact`, both the embedded prompt and the stored
response contain redaction tokens (`[EMAIL_1]`, ...), never original values.
`redact`'s existing `body_filter` restores tokens on every response path,
including cache HITs, using the per-request `ctx.redact_token_map`. PostgreSQL
therefore holds no PII, and the embedding service never sees PII.

### 2.5 No cache-adapter sidecar

The only auxiliary service is the local `llama-server` embedding endpoint.
PostgreSQL is reached with plain parameterized SQL over `pgmoon`.

## 3. System Diagram

```
APISIX custom Lua plugin (semantic-cache)           llama-server (llama.cpp)
+-----------------------------------------+        +----------------------+
| access phase (priority 2450, after       |        | OpenAI-compatible    |
| redact 2500 has tokenized the body):     |  POST  | POST /v1/embeddings  |
|   extract messages from request body     | -----> | harrier-oss-v1 GGUF  |
|   call llama-server embeddings (cosocket)|        | (0.6b | 270m profile)|
|   query pgvector (SQL, cosocket)         |        | last-token pooling   |
|   if HIT: return tokenized body; redact  | <----- | returns float[]      |
|           body_filter rehydrates tokens  |        +----------------------+
|   if MISS: stash prompt/tenant in ctx    |
| body_filter: buffer chunks on MISS       |
| log phase (ngx.timer.at):                |
|   INSERT + expiry for tokenized response |
+-----------------------------------------+
                                            PostgreSQL 17 + pgvector 0.8
                                            +----------------------+
                                            | semantic_cache_<profile>_<dim> |
                                            | halfvec(768) + HNSW cosine     |
                                            | (tenant_id, tier) predicate +  |
                                            | iterative scan                 |
                                            +----------------------+
```

## 4. Plugin Manifest and Schema

| Property | Value |
|----------|-------|
| name | `semantic-cache` |
| version | 0.1 |
| priority | 2450 (after `redact` at 2500, before `sse-usage` at 2400) |

| Schema property | Type | Default | Purpose |
|-----------------|------|---------|---------|
| `embedding_url` | string (required) | - | llama-server embeddings endpoint |
| `embedding_model` | string | `harrier-oss-v1-0.6b` | Model id sent to llama-server |
| `embedding_dim` | integer | 1024 | Expected vector dimension (1024 or 640) |
| `embedding_profile` | string | `quality` | Cache namespace: `quality` (1024d) / `latency` (640d) |
| `query_prefix` | string | `Instruct: Given a user prompt, retrieve semantically equivalent prompts\nQuery: ` | Task instruction prepended to the embedded prompt |
| `pg_host` | string | `127.0.0.1` | PostgreSQL host |
| `pg_port` | integer | 5432 | PostgreSQL port |
| `pg_database` | string | `gateway` | Database name |
| `pg_user` | string | `semcache` | Least-privilege role |
| `pg_password` | string | - | Role password (from OpenBao/.env) |
| `table` | string | `semantic_cache_quality_1024` | Profile table (must match `embedding_dim`) |
| `distance_threshold` | number | 0.10 | Cosine distance `[0,2]`; 0.10 ~ 0.90 similarity |
| `cache_ttl_seconds` | integer | 300 | Entry TTL |
| `timeout_ms` | integer | 2000 | Cosocket timeout |
| `message_countback` | integer | 1 | Trailing messages used for prompt text |
| `ignore_system_prompts` | boolean | true | Skip system role messages |
| `stop_on_failure` | boolean | false | Opt-in 503 on infra failure |

`embedding_dim`, `embedding_profile`, and `table` MUST agree; the schema
rejects a mismatch. The two shipped profiles are separate namespaces because
their embedding spaces are incompatible (see §8.4).

## 5. Access Phase Algorithm

1. Read `x-tenant-id` / `x-routing-tier`; missing or empty -> 403
   `missing_isolation_metadata`.
2. Read the (already redacted) request body from `ngx.req.get_body_data()`;
   require `messages`.
3. Extract prompt text (trailing N messages, system skipped per config).
4. Prepend `query_prefix`; POST `{model, input}` to `embedding_url` via
   `resty.http` cosocket. Non-200 or unreachable -> `ctx.cache_status =
   "MISS-EMBED-FAIL"`, proceed.
5. Validate `data[1].embedding` exists and `#vector == embedding_dim`;
   otherwise MISS (`MISS-EMBED-MALFORMED` / `MISS-EMBED-DIM-MISMATCH`).
6. Format the vector as a pgvector literal `'[0.1,0.2,...]'` (no binary
   packing needed over the text protocol).
7. Query pgvector over a `pgmoon` cosocket connection:

```sql
SELECT response, stream_mode, format,
       1 - (embedding <=> $1::halfvec) AS distance
  FROM semantic_cache_quality_1024
 WHERE tenant_id = $2
   AND tier = $3
   AND expires_at > now()
 ORDER BY embedding <=> $1::halfvec
 LIMIT 1
```

   Follow the query with `SET LOCAL hnsw.iterative_scan = relaxed_order` (or
   set it on the role/session) so filtered searches keep recall.
8. On hit with `distance <= distance_threshold`, frame the response per §7 and
   return 200 with `X-Cache: HIT`. On miss, stash
   `{vector, prompt, tenant, tier, stream, request_body}` in `ctx`.

`pgmoon` returns the result set decoded; `embedding <=> $1` uses the HNSW
cosine operator and the index is used because the `ORDER BY` matches the
operator class.

## 6. Body Filter and Log Phase

- `body_filter`: if `ctx.cache_miss`, append `ngx.arg[1]` to
  `ctx.cache_response_buffer` without modifying the chunk stream.
- Canonicalization: SSE frames are parsed (`data: {...}\n\n` up to
  `data: [DONE]`), delta contents concatenated, and re-encoded as
  `{"choices":[{"message":{"role":"assistant","content":"..."}}]}`. Both the
  canonical JSON and the raw response are tokenized (post-`redact`), so no
  rehydration is needed before storage.
- `log`: if `ctx.cache_miss` and a captured buffer exists, canonicalize and
  store off-thread via `ngx.timer.at`:

```sql
INSERT INTO semantic_cache_quality_1024
    (embedding, prompt, response, stream_mode, format,
     tenant_id, tier, expires_at)
VALUES ($1::halfvec, $2, $3, $4, $5, $6, $7, now() + ($8 || ' seconds')::interval)
```

Store failure: log and drop; never retry. Expired rows are removed by a
periodic `DELETE ... WHERE expires_at < now()` job (or native partitioning);
the read path also filters on `expires_at`.

## 7. Streaming Replay

Because the plugin runs after `redact`, the stored response is tokenized. The
cache replays the tokenized body and lets `redact.body_filter` restore tokens,
so replay needs no token map of its own.

| Stored mode | Client `stream` | Result |
|-------------|-----------------|--------|
| json | false | `application/json`, body as-is |
| json | true | `text/event-stream`, synthesized SSE |
| sse | false | `application/json`, parsed to canonical JSON |
| sse | true | `text/event-stream`, body as-is |

SSE synthesis from JSON: initial role delta frame, per-word content frames,
final frame with `finish_reason: "stop"`, then `data: [DONE]\n\n`.

## 8. Embedding Service Contract (llama.cpp)

The embedding service is stock `llama-server` from llama.cpp, running a
quantized GGUF. There is no hand-written sidecar: llama.cpp provides
continuous batching, the OpenAI endpoints, `/health`, `--api-key`, and
`--metrics`.

### 8.1 `POST /v1/embeddings`

Request: `{"model": "harrier-oss-v1-0.6b", "input": "<prompt text>"}`

Response (200):

```json
{
  "data": [{ "embedding": [0.0123, -0.0456], "index": 0 }],
  "model": "harrier-oss-v1-0.6b",
  "usage": { "prompt_tokens": 8, "total_tokens": 8 }
}
```

### 8.2 `GET /health`

```json
{"status":"ok"}
```

### 8.3 Model profiles

| Profile | Model (GGUF) | Params | Dims | Pooling | License | Quant | Size |
|---------|--------------|--------|------|---------|---------|-------|------|
| `quality` | `microsoft/harrier-oss-v1-0.6b` | 0.6B | 1024 | last-token | MIT | Q8_0 | ~610 MB |
| `latency` | `microsoft/harrier-oss-v1-270m` | 0.27B | 640 | last-token | MIT | Q8_0 | ~287 MB |

Both are 2026-current `harrier-oss-v1` releases. On MTEB (Multilingual, v2)
Mean(Task) they score **69.0** (0.6b) and **66.5** (270m), versus 64.3 for
Qwen3-Embedding-0.6B and 61.15 for EmbeddingGemma-300M. `harrier-0.6b` is a
Qwen3-0.6B fine-tune; `harrier-270m` is Gemma3-based. Start commands:

```sh
# quality
llama-server -m harrier-oss-v1-0.6b-Q8_0.gguf \
  --embeddings --pooling last --embd-normalize 2 \
  --host 0.0.0.0 --port 8080 --metrics --api-key "$EMBED_KEY"

# latency
llama-server -m harrier-oss-v1-270m-Q8_0.gguf \
  --embeddings --pooling last --embd-normalize 2 \
  --host 0.0.0.0 --port 8080 --metrics --api-key "$EMBED_KEY"
```

### 8.4 Profiles are separate namespaces

The two models are different architectures and dimensions, so their embedding
spaces are **incompatible**: a `latency` vector MUST NOT be searched against
the `quality` index or vice versa. Each profile has its own table and its own
cache namespace. Cross-profile lookup is forbidden.

### 8.5 Prompt prefixes

`harrier-oss-v1` queries require a task instruction prefix
(`Instruct: ...\nQuery: ...`); documents/passages are embedded without one.
The gateway owns prefixing (`query_prefix`) so the embedding service stays a
dumb, interchangeable OpenAI endpoint.

### 8.6 Backend substitution

The service is consumed only through `/v1/embeddings`. If a local benchmark
shows ONNX Runtime, OpenVINO, CTranslate2, or Text Embeddings Inference (TEI)
beats llama.cpp on the target CPU, the service may be swapped without touching
the Lua plugin. llama.cpp was chosen for GGUF support, the smallest memory
footprint, and best-in-class CPU portability; its CPU throughput is not
assumed to be the fastest (see REQ §6 benchmark gate).

### 8.7 GGUF correctness gate

Embedding GGUFs are not interchangeable blindly. Known footguns:

- Decoder embedding GGUFs must include the SentenceTransformer dense modules;
  a conversion missing them produces a completely different vector
  (llama.cpp #19040). Pin a conversion verified against the HuggingFace
  reference.
- `--pooling` must match the model (`last` for `harrier-oss-v1`; `mean` for
  `embeddinggemma-300m`).
- Quantization below ~4 BPW lowers retrieval quality; TQ1/TQ2 diverge on some
  architectures. Use Q8_0 or Q6_K.

A golden-vector check (cosine vs the reference model on fixed strings) is a
deploy-time gate; a mismatch blocks rollout.

## 9. pgvector Schema

### 9.1 Extension and role

```sql
CREATE EXTENSION IF NOT EXISTS vector;
```

A dedicated least-privilege role owns the cache tables; it has no access to
any other schema. The connection stays on the internal `gw-cache` network (no
published host port).

### 9.2 Table (per profile)

```sql
CREATE TABLE IF NOT EXISTS {{ TABLE }} (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    embedding   halfvec({{ DIM }}) NOT NULL,
    prompt      text NOT NULL,
    response    text NOT NULL,
    stream_mode text NOT NULL,
    format      text NOT NULL,
    tenant_id   text NOT NULL,
    tier        text NOT NULL,
    expires_at  timestamptz NOT NULL
);

CREATE INDEX IF NOT EXISTS {{ TABLE }}_embedding_idx
    ON {{ TABLE }}
    USING hnsw (embedding halfvec_cosine_ops)
    WITH (m = 16, ef_construction = 200);

CREATE INDEX IF NOT EXISTS {{ TABLE }}_scope_idx
    ON {{ TABLE }} (tenant_id, tier, expires_at);
```

`halfvec` stores fp16, halving index and storage versus `vector` with
negligible quality loss at these dimensions. Cosine distance `[0, 2]`; 0 =
identical. Default threshold 0.10 equals cosine similarity >= 0.90.

### 9.3 Filtered recall

HNSW answers `ORDER BY embedding <=> $1 LIMIT 1` with the index; applying a
`tenant_id`/`tier` predicate naively can drop recall when a tenant's rows are
sparse. Enable pgvector's iterative index scan for the session/role:

```sql
SET hnsw.iterative_scan = relaxed_order;
```

This keeps scanning the index until enough rows survive the predicate,
preserving per-tenant recall without a per-tenant index.

## 10. Failure Modes

| Failure | Detection | Action |
|---------|-----------|--------|
| Tenant/tier header missing | header check | 403 (fail closed) |
| llama-server 5xx/unreachable/timeout | httpc nil or 5xx | MISS, `X-Cache: MISS-EMBED-FAIL` |
| Embedding wrong dim | `#vector != embedding_dim` | MISS, never store |
| pgmoon connect/query failure or timeout | `res == nil` | MISS, `X-Cache: MISS-QUERY-FAIL` |
| Distance above threshold | `hit.distance > threshold` | normal MISS, forward + store |
| Store failure in log phase | `res == nil` | log, no retry |
| `stop_on_failure: true` | any of above | 503 (per-route opt-in only) |

## 11. Edge Cases & Decisions

- **Streaming client, JSON-stored entry:** synthesize SSE; do not store SSE.
- **Store tokenized:** canonical JSON is stored exactly as returned upstream
  (post-redaction); `redact` rehydrates on every response path including HITs.
- **Cache HITs skip `sse-usage` (2400) and `limit-count` (2002):** HITs do not
  reach upstream, so there are no upstream tokens to bill and no provider
  load to rate-limit. Cache HIT/MISS counters are emitted by the plugin itself.
- **`query_prefix` per profile:** the `quality` (Qwen3-based) and `latency`
  (Gemma3-based) profiles use their own instruction formats; the prefix is
  plugin config, not hard-coded per model.
- **Filtered HNSW recall:** requires iterative scan (§9.3); without it, small
  tenants can miss relevant rows.

## 12. File Map

| File | Purpose | Key Changes |
|------|---------|-------------|
| `plugins/custom/semantic-cache.lua` (planned) | Plugin: access/body_filter/log | new file |
| `conf/sql/pgvector/semantic_cache.sql` (planned) | Profile table + HNSW DDL template | new file |
| `conf/sql/pgvector/.sqlfluff` (planned) | `dialect = postgres` override | new file |
| `res/scripts/bench-embedding.sh` (planned) | Golden-vector + latency + recall gate | new file |
| `conf/config.yaml` (planned edit) | register `semantic-cache` in `plugins:` | add entry |
| `conf/apisix.yaml` (planned edit) | per-route plugin config | add plugin block to relay routes |
| `res/docker/docker-compose.yml` (planned edit) | `postgres` (pgvector) + `llama-server` services, `gw-cache` network | add services |
| `res/docker/Dockerfile.apisix` (planned edit) | install `pgmoon` | add layer |

## 13. Implementation Status

| Component | Status | Evidence |
|-----------|--------|----------|
| `plugins/custom/semantic-cache.lua` | Not implemented | file does not exist; grep `semantic` in `plugins/custom/` returns no match |
| Plugin registration | Not implemented | `conf/config.yaml` `plugins:` list contains no `semantic-cache` |
| Route configuration | Not implemented | `conf/apisix.yaml` contains no `semantic-cache` reference |
| llama.cpp embedding service | Not implemented | no `llama-server` service or GGUF in deployment configs |
| pgvector schema bootstrap | Not implemented | no `CREATE EXTENSION vector` / `semantic_cache` DDL in `conf/`, `res/`, or `tests/` |
| `pgmoon` dependency | Not implemented | not installed in `res/docker/Dockerfile.apisix` |
| Tests | Not implemented | no `tests/**` referencing semantic cache |
