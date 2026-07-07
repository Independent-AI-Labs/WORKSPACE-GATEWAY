# High-Performance Enterprise Multi-Tenant LLM Gateway - Architecture Proposal v3.0

**Document ID:** AMI-PROP-LLMGW-v3.0
**Status:** Draft
**Date:** 2026-07-05
**Supersedes:** AMI-PROP-LLMGW-v2.0 (Kong Gateway architecture, archived)
**Classification:** Internal - Enterprise
**Authors:** AMI-Agents Engineering

---

## 0. Pivot Rationale: Kong to Apache APISIX

The v2.0 proposal built on Kong Gateway 3.14 (Enterprise image run unlicensed) with
four custom Rust Proxy-Wasm plugins to replace Enterprise-only capabilities. Deep
research revealed structural problems with this approach:

| Problem (Kong) | Resolution (APISIX) |
|----------------|---------------------|
| Kong 3.14 Enterprise code is private; public repo source stops at 3.9.3; 3.14 was never tagged on GitHub | APISIX source is fully public; release tags for every version 3.0-3.17.0 |
| Free mode deprecated since 3.10, **removed in 3.15**; Admin API becomes read-only; DB-less breaks on restart | Apache 2.0, no license enforcement, no tier split, no "free mode" cliff |
| `openid-connect`, `ldap-auth-advanced`, `ai-proxy-advanced`, `ai-semantic-cache` all Enterprise-only | ALL plugins are OSS in APISIX, `openid-connect`, `ldap-auth`, `ai-proxy`, `ai-proxy-multi`, `ai-rate-limiting`, `proxy-cache` |
| Custom Rust Wasm filters require `wasm32-wasip1` toolchain, `dispatch_http_call` async state machines, `meta.json` Draft-4 schemas, no socket access | Pure Lua plugins: synchronous cosockets, `lua-resty-http`/`lua-resty-redis`, same OpenResty phase model |
| 4 Rust sidecar binaries (redact-engine, ldap-bridge, cache-adapter, failover-translator) | 0 sidecars in v1; 2 optional in v2 (NER + embedding) |
| decK + Admin API + PostgreSQL for GitOps | Standalone YAML mode (file-driven hot reload) or ADC (`adc sync`) for GitOps |

**Net architectural shift:** 5 custom plugin implementations (2 Rust Wasm + 1 Lua + 2
hybrid) reduced to **2 custom Lua plugins** (redaction, semantic-cache). Auth,
failover, rate-limiting, AI proxy, and telemetry are all APISIX built-in plugins
requiring configuration only, zero custom code.

---

## 1. Scope

This document specifies the architecture for a unified, multi-tenant LLM Gateway
built on **Apache APISIX 3.17.0** in **standalone YAML mode**, with two custom Lua
plugins (redaction, semantic-cache) and APISIX built-in plugins for all other
capabilities. It governs identity integration, per-user virtual-token billing, PII
anonymization/re-hydration, and edge intelligence (semantic cache, multi-provider
failover).

**In scope:**
- APISIX data plane configuration and custom plugin contracts.
- Billing-grade token accounting with reconciliation (transfers from v2.0).
- PII redaction via pure Lua regex + file-based dictionaries.
- Semantic cache via Lua + Redis VSS cosocket (v2 spec; embedding sidecar deferred).

**Out of scope (deferred to per-plugin specs):**
- Internal implementation of custom Lua plugins (`PLUGIN-REDACT-LUA`, `PLUGIN-SEMANTIC-CACHE`).
- APISIX built-in plugin configuration details (`BUILTIN-PLUGINS.md`).
- Deployment infrastructure (`DEPLOYMENT.md`).

---

## 2. Terminology

| Term | Definition |
|------|-----------|
| Data Plane | The APISIX gateway instance(s) executing request/auth/proxy/redaction logic. |
| Control Plane | `apisix.yaml` file (standalone mode) or ADC `adc sync` for GitOps. |
| IdP | Identity Provider, Keycloak, Entra ID, or raw Active Directory (LDAP/Kerberos). |
| Context Pattern | Standardized `ctx` + header injection of `X-Tenant-ID`, `X-User-ID`, `X-Routing-Tier`. |
| PII Map | The per-request `{placeholder -> original}` association used for re-hydration. |
| Reconciler | A daily offline job cross-checking APISIX usage logs against provider billing APIs. |

---

## 3. Architecture Overview

```
[ Inbound App Clients ]
        | (JWT / Bearer / LDAP credentials)
        v
+----------------------------------------------------------------+
| APISIX AI DATA PLANE  (Apache APISIX 3.17.0, standalone YAML)  |
|                                                                |
|  Phase 1: Unified Auth (built-in plugins)                     |
|    openid-connect   cached-JWKS JWT validation (Keycloak/Entra)|
|    ldap-auth         LDAP bind against AD DC                   |
|    -> injects X-Tenant-ID / X-User-ID / X-Routing-Tier         |
|                                                                |
|  Phase 2: PII Anonymization (custom Lua plugin)               |
|    redact   regex + file-based dictionary detection            |
|             PII Map stashed in ctx (per-request)               |
|             response: body_filter re-hydration (local gsub)    |
|             v2: NER sidecar via ngx.timer.at (off-thread)      |
|                                                                |
|  Phase 3: AI Proxy + Routing (built-in plugins)               |
|    semantic-cache   Redis VSS cosine cache (v2, custom Lua)    |
|    ai-proxy-multi   weighted LB + failover + retry             |
|    ai-proxy         provider format translation (OpenAI format)|
|    ai-rate-limiting per-consumer, per-model token limits       |
|    proxy-buffering  disabled per-route for SSE                 |
|                                                                |
|  Log phase (off-thread, ngx.timer.at):                        |
|    http-logger  -> Vector -> ClickHouse (billing ledger)       |
|    prometheus   -> real-time alerts                            |
+----------------------------------------------------------------+
        | (Stripped PII + Per-target API key)
        v
[ Upstream Providers ]  (OpenAI / Azure / Bedrock / Anthropic / vLLM)

[ Redis 8 (VSS) ]   <- semantic cache vectors + optional PII map durability
[ ClickHouse ]      <- billing ledger
[ Vector ]          <- telemetry ingest
[ Keycloak ]        <- OIDC IdP (from DATAOPS)

[ v2 Sidecars ]
  ner-engine      : Rust binary, ONNX BERT-tiny, POST /ner (off-thread)
  embedding-service : Rust binary, torch/llama.cpp, POST /v1/embeddings
```

---

## 4. Plugin Mapping: Kong Enterprise to APISIX Built-in

| Kong Enterprise plugin (OSS-missing) | APISIX built-in replacement | Custom code? |
|---------------------------------------|----------------------------|--------------|
| `openid-connect` | `openid-connect` | No, config only |
| `ldap-auth-advanced` | `ldap-auth` / `forward-auth` | No, config only |
| `ai-proxy-advanced` | `ai-proxy-multi` | No, config only |
| `ai-semantic-cache` | Custom Lua `semantic-cache` | Yes, Lua plugin (v2) |
| `ai-proxy` (OSS) | `ai-proxy` | No, config only |
| Rate limiting | `ai-rate-limiting` | No, config only |
| Telemetry (`http-log`/`tcp-log`) | `http-logger` + `prometheus` | No, config only |
| SSE buffering control | `proxy-buffering` | No, config only |
| PII redaction (no Kong equivalent) | Custom Lua `redact` | Yes, Lua plugin (v1) |

**Custom code reduced from 5 plugins to 2.** No Rust Wasm toolchain. No
`dispatch_http_call` async state machines. No `meta.json` Draft-4 schemas.

---

## 5. Requirement 1 - Unified Multi-Identity Integration

The gateway authenticates OIDC (Keycloak/Entra) and legacy Windows AD (LDAP) without
an internal user database, using APISIX built-in plugins.

### 5.1 OIDC: `openid-connect` (built-in)

- Stateless JWT validation against cached JWKS.
- `bearer_only: true` for API-only routes (no login flow; validate bearer token).
- Multi-issuer: one `openid-connect` plugin instance per route, per issuer.
- Claim mapping: `X-Tenant-ID` from tenant claim, `X-User-ID` from `sub`,
  `X-Routing-Tier` from group claim. Configured via `claims_to_header` mapping.
- JWKS caching in `ngx.shared.DICT` (shared across workers).

### 5.2 LDAP: `ldap-auth` (built-in)

- LDAP simple bind against AD Domain Controller pool.
- `ldap_uri`, `base_dn`, `bind_dn` configured per route.
- For Kerberos SPN validation: `forward-auth` plugin delegating to an external
  auth service (v2 enhancement; `ldap-auth` covers LDAP bind in v1).

### 5.3 Unified Context Headers

After either auth plugin succeeds, the following headers are injected (via APISIX
plugin config `claims_to_header` or `ldap-auth` attribute mapping):

| Header | Source | Verification |
|--------|--------|--------------|
| `X-Tenant-ID` | tenant claim / AD attribute | cryptographically bound to verified token |
| `X-User-ID` | OIDC `sub` / AD `sAMAccountName` | set only by the auth plugin |
| `X-Routing-Tier` | group claim / AD group mapping | used by cache/failover for tiered routing |

Downstream plugins read from `ctx` or request headers. The `redact` or a tiny
header-hygiene plugin strips these before egress to upstream LLM providers.

---

## 6. Requirement 2 - Per-User Virtual-Token Billing (Billing-Grade)

### 6.1 Telemetry pipeline

```
APISIX log phase (http-logger, AFTER response sent)
     |
     | ai.proxy.usage.* + custom plugin fields assembled
     v
Vector (http-logger sink)  --  Prometheus exporter (real-time alerts)
     |
     v
ClickHouse (columnar, TTL-partitioned billing ledger)
     |
     v
Reconciler (daily)  ->  compares ClickHouse to OpenAI/Azure usage APIs
```

### 6.2 Billing-grade contract (mandatory)

APISIX `ai-proxy` provides token usage in the log phase via `logging.summaries`.
The gateway enforces:

1. **`stream_options.include_usage: true`** on every streaming route. Configured
   in `ai-proxy` plugin config; enforced per-provider (OpenAI/Azure/vLLM support it).
2. **Token breakdown stored separately**, `prompt_tokens`, `completion_tokens`,
   `reasoning_tokens`, `cached_tokens`, never summed into a single field for
   billing math.
3. **Rate snapshots**, `rate_input`, `rate_output`, `currency` written at request
   time so historical bills are reproducible after rate changes.
4. **Reconciler job**, daily offline process pulls upstream provider billing APIs,
   flags divergence beyond configurable tolerance per (tenant, provider, model, day).
   Divergence emitted to `billing_discrepancies` table; never silently discarded.

### 6.3 ClickHouse schema

```sql
CREATE TABLE llm_billing_ledger (
    event_id         String,
    tenant_id        LowCardinality(String),
    user_id          String,
    provider         LowCardinality(String),
    model_name       LowCardinality(String),
    route_name       LowCardinality(String),
    consumer_group   LowCardinality(String),
    request_mode     LowCardinality(String),
    cache_status     LowCardinality(String),
    prompt_tokens    UInt32,
    completion_tokens UInt32,
    reasoning_tokens UInt32,
    cached_tokens    UInt32,
    total_tokens     UInt32,
    rate_input       Decimal64(8),
    rate_output      Decimal64(8),
    currency         LowCardinality(String),
    cost             Decimal64(6),
    success          Bool,
    error_type       LowCardinality(String),
    llm_latency_ms   UInt32,
    ttft_ms          UInt32,
    upstream_resp_id LowCardinality(String),
    redact_active    Bool DEFAULT false,
    redact_placeholder_count UInt32 DEFAULT 0,
    timestamp        DateTime64(3) DEFAULT now()
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (tenant_id, user_id, timestamp)
TTL timestamp + INTERVAL 13 MONTH
SETTINGS index_granularity = 8192;
```

`cost Decimal64(6)` (NOT `Float64`, MPP aggregates non-deterministic with floats).
ORDER BY leads with low-cardinality filtering keys for prefix-pruned per-tenant
aggregate queries. TTL 13 months for high-volume retention without `Too many parts`.

---

## 7. Requirement 3 - Real-Time PII Anonymization (Custom Lua, v1)

### 7.1 Redaction hot path (pure Lua, in-process)

- **Regex detection** via `ngx.re` (PCRE C bindings, not interpreted Lua). Patterns
  for email, SSN, credit card (with Luhn check), API key, phone, JWT, IP.
- **File-based dictionary** of sensitive string patterns (organization names, project
  codes, internal system identifiers). Loaded at init from a YAML file; matched via
  PCRE alternation (`org1|org2|org3|...`, PCRE optimizes with internal trie) or
  `lua-resty-aho-corasick` FFI if available.
- Original PII -> safe placeholder (`[EMAIL_1]`, `[CUSTOMER_NAME_1]`). PII Map
  stashed in `ctx` (per-request, zero-copy table access).
- `Content-Length` cleared in `header_filter` (before body_filter; headers are
  flushed after that).
- Cross-chunk sliding window: SSE responses stream as multiple chunks; a placeholder
  may span a chunk boundary. The Lua matcher keeps a tail buffer across `body_filter`
  invocations so partial placeholders are rehydrated correctly.
- **Zero IPC on the hot path.** No sidecar call. No serialization. No network.

### 7.2 Heavy NER (off-thread sidecar, v2)

Structural NER (Person/Org/Location) is beyond inline regex. It runs in a **Rust
sidecar binary** (ONNX Runtime, BERT-tiny int8), invoked **off the request thread**
via `ngx.timer.at`:

1. Lua plugin passes text slice + correlation ID to the timer.
2. Timer POSTs to sidecar's `POST /ner` endpoint (cosocket, non-blocking).
3. Results written to PII Map in `ctx` (if the sidecar returns before re-hydration).
4. If sidecar hasn't returned, re-hydration falls back to regex-only for that segment.

The data plane never blocks the client on the sidecar. See `PLUGIN-REDACT-ENGINE.md`.

### 7.3 Security guarantee

Upstream LLM providers never see original PII, only placeholders. PII is re-injected
only as the outbound stream passes back through the Lua `body_filter`. The PII Map
never leaves the gateway data plane.

---

## 8. Requirement 4 - Edge Intelligence

### 8.1 Semantic Cache (custom Lua, v2 spec)

- Vector similarity cache against Redis VSS. On a request, compute an embedding
  (via Rust embedding sidecar with torch/llama.cpp), query Redis for nearest
  neighbor within a cosine threshold (default 0.95 similarity / 0.10 distance).
- Hit -> respond immediately from cache; record `cache_status=hit` in billing
  ledger (no upstream token charge).
- Miss -> forward to upstream; on success cache the response keyed by embedding.
- Redis VSS query via `lua-resty-redis` cosocket (`FT.SEARCH` with KNN + TAG
  pre-filter). No cache-adapter sidecar needed.
- Tenant- and tier-scoped: `X-Tenant-ID` and `X-Routing-Tier` are TAG fields in
  the Redis index; a hit in one tenant never leaks to another.

### 8.2 Multi-Provider Failover (built-in `ai-proxy-multi`)

- Weighted multi-target routing across OpenAI / Azure / Bedrock / Anthropic / vLLM.
- Built-in: priority groups, weighted LB, `fallback_strategy` (rate_limiting,
  http_429, http_5xx), `max_retries`, active health checks.
- `stream_options.include_usage` enforced via `ai-proxy` config.
- Context headers (`X-Tenant-ID` etc.) stripped before egress, handled by
  `proxy-rewrite` built-in or a tiny Lua header-hygiene plugin.

---

## 9. Infrastructure (Standalone YAML Mode)

### 9.1 Deployment mode

APISIX runs in **standalone YAML mode** (`deployment.role: data_plane`,
`config_provider: yaml`). The `apisix.yaml` file at `/usr/local/apisix/conf/`
defines all routes, services, upstreams, and plugin configs. APISIX polls the
file every 1 second for changes, hot reload without restart, no etcd needed.

For multi-node deployment or Admin API access, switch to **traditional mode**
with etcd. ADC (`adc sync`) provides GitOps config management in traditional mode.

### 9.2 Custom Docker image

```dockerfile
FROM apache/apisix:3.17.0-debian
COPY plugins/custom/ /usr/local/apisix/apisix/plugins/custom/
COPY conf/config.yaml /usr/local/apisix/conf/config.yaml
COPY conf/apisix.yaml /usr/local/apisix/conf/apisix.yaml
COPY conf/redact-patterns.yaml /etc/apisix/redact-patterns.yaml
```

See `DEPLOYMENT.md` for full docker-compose stack, `config.yaml`, and
`apisix.yaml` route definitions.

### 9.3 Shared DATAOPS services

Reused from the existing DATAOPS compose stack:
- **Redis 8** (`ami-redis:6379`), VSS for semantic cache, optional PII map durability
- **Keycloak 26.2** (`ami-keycloak:8082`), OIDC IdP
- **PostgreSQL/pgvector** (`ami-postgres:5432`), not needed by APISIX in standalone mode
- **Prometheus** (`ami-prometheus:9091`), real-time metrics
- **OpenBao** (`ami-openbao:8200`), secrets (API keys, LDAP creds)

New services to deploy:
- **ClickHouse**, billing ledger
- **Vector**, telemetry ingest from `http-logger`
- **APISIX**, the gateway itself

---

## 10. Sidecar Inventory

| Sidecar | Version | Listens on | Purpose |
|---------|---------|-----------|---------|
| (none) | v1 | N/A | All hot-path logic in pure Lua; auth/failover/rate-limit built-in |
| `ner-engine` | v2 | `127.0.0.1:8081` | Rust binary, ONNX BERT-tiny, `POST /ner` (off-thread enrichment) |
| `embedding-service` | v2 | `127.0.0.1:8090` | Rust binary, torch/llama.cpp, `POST /v1/embeddings` (local model, not OpenAI API) |

**v1 has zero sidecars.** The entire gateway is APISIX + Redis + ClickHouse + Vector,
all configured via YAML. v2 adds two optional Rust sidecar binaries for NER and
local embedding model support.

---

## 11. Strategic Action Items

1. **Build custom APISIX Docker image** with `redact` Lua plugin, `config.yaml`,
   `apisix.yaml`, and `redact-patterns.yaml`.
2. **Configure `openid-connect`** against Keycloak (`ami-keycloak:8082`); verify
   claim-to-header mapping for `X-Tenant-ID` / `X-User-ID` / `X-Routing-Tier`.
3. **Configure `ai-proxy-multi`** with OpenAI + Azure targets; verify weighted LB,
   failover on 429, and `stream_options.include_usage` enforcement.
4. **Implement `redact` Lua plugin**, regex + dictionary detection, PII map in
   `ctx`, `body_filter` re-hydration with cross-chunk sliding window. Benchmark
   under realistic SSE chunk sizes.
5. **Provision ClickHouse + Vector**, `http-logger` sends log payloads to Vector;
   Vector writes to `llm_billing_ledger`. Build daily reconciler job.
6. **v2: Implement `semantic-cache` Lua plugin**, Redis VSS cosocket, embedding
   sidecar, canonical-JSON storage with SSE synthesis on HIT.
7. **v2: Build `ner-engine` and `embedding-service` Rust sidecars**, ONNX BERT-tiny
   and torch/llama.cpp embedding model, respectively.

---

## 12. Open Questions

| Question | Owner follow-up |
|----------|-----------------|
| APISIX `openid-connect` claim-to-header mapping for custom claims (`tenant_id`, `routing_tier`) | `BUILTIN-PLUGINS.md` |
| `ai-proxy-multi` health check semantics for LLM providers (OpenAI `/v1/models` as liveness?) | `BUILTIN-PLUGINS.md` |
| `ai-proxy` `stream_options` config field name and per-provider support matrix | `BUILTIN-PLUGINS.md` |
| Redis VSS `FT.SEARCH` binary blob packing in `lua-resty-redis` (ffi float32) | `PLUGIN-SEMANTIC-CACHE.md` |
| Redact-patterns YAML schema and hot-reload mechanism | `PLUGIN-REDACT-LUA.md` |
| ClickHouse reconciler job implementation (cron, Python/bash, divergence tolerance) | `DEPLOYMENT.md` |

---

## 13. References

- Apache APISIX: https://apisix.apache.org/
- APISIX plugin development: https://apisix.apache.org/docs/apisix/plugin-develop/
- APISIX standalone mode: https://apisix.apache.org/docs/apisix/deployment-modes/
- APISIX `openid-connect` plugin: https://apisix.apache.org/docs/apisix/plugins/openid-connect/
- APISIX `ai-proxy` / `ai-proxy-multi`: https://apisix.apache.org/docs/apisix/plugins/ai-proxy/
- APISIX `ai-rate-limiting`: https://apisix.apache.org/docs/apisix/plugins/ai-rate-limiting/
- APISIX `proxy-buffering` (PR #13446, merged in 3.17.0): https://github.com/apache/apisix/pull/13446
- APISIX `http-logger`: https://apisix.apache.org/docs/apisix/plugins/http-logger/
- APISIX `prometheus`: https://apisix.apache.org/docs/apisix/plugins/prometheus/
- APISIX ADC CLI: https://github.com/api7/adc
- Redis VSS FT.SEARCH + KNN: https://redis.io/docs/latest/develop/ai/search-and-query/vectors/
- ClickHouse Decimal vs Float for money: https://clickhouse.com/docs/sql-reference/data-types/float
- OpenResty cosocket phases: https://github.com/openresty/lua-nginx-module#cosockets
- `lua-resty-http`: https://github.com/ledgetech/lua-resty-http
- `lua-resty-redis`: https://github.com/openresty/lua-resty-redis

---

**End of document.**
