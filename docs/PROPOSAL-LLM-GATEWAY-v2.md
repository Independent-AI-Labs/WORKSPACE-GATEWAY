# High-Performance Enterprise Multi-Tenant LLM Gateway - Revised Architecture Proposal

**Document ID:** AMI-PROP-LLMGW-v2.0
**Status:** Draft (Revised)
**Date:** 2026-07-04
**Supersedes:** AMI-PROP-LLMGW-v1.0 (original "Kong OSS" proposal)
**Classification:** Internal - Enterprise
**Authors:** AMI-Agents Engineering

---

## 0. Revision Summary and Rationale

The original proposal (v1.0) was titled "Kong Gateway (OSS)" but technical due-diligence
revealed that **three of the five advertised capabilities are Kong Enterprise-only** and that
several core technical claims were infeasible as stated. This revision corrects the architecture
to a defensible OSS-only design and defers the replaced Enterprise features to a set of custom
Rust Proxy-Wasm plugins to be specified in follow-up documents.

**Material corrections in v2.0:**

| # | v1.0 claim | Finding | v2.0 resolution |
|---|-----------|---------|-----------------|
| 1 | "Kong OSS" delivers OIDC, raw-AD/LDAP, multi-provider failover, semantic cache | `openid-connect`, `ldap-auth(-advanced)`, `ai-proxy-advanced`, `ai-semantic-cache` are all `tier: enterprise` / `tier: ai_gateway_enterprise` | OSS Kong core retained; the four Enterprise capabilities are rebuilt as **custom Rust Proxy-Wasm plugins** (Specked in follow-up docs: `PLUGIN-AUTH-*`, `PLUGIN-FAILOVER`, `PLUGIN-SEMANTIC-CACHE`) |
| 2 | "Rust WASM filter persists state to Redis directly" | Proxy-Wasm exposes no socket syscall; only `dispatch_http_call` / `dispatch_grpc_call`. The Rust `redis` crate cannot compile/run inside the guest. | Anonymizer (Req 3) is reimplemented as a **Lua plugin** using `kong.ctx.plugin` for per-stream mapping + `lua-resty-redis` for optional cross-worker durability. The Wasm/Rust engineering budget is redirected to the four custom plugins above. |
| 3 | "Lightweight local quantized NER inside the Wasm filter" | nginx workers are single-threaded; a BERT forward pass blocks all connections. No `wasi-nn` hostcall in the Proxy-Wasm ABI. Per-request Wasm instantiation is ~0.6-0.8s. | Inline Lua + Aho-Corasick regex/dictionary detection only. Heavy NER runs in a **sidecar service** opened via `ngx.timer.at` / `kong.async` (off-request-thread). |
| 4 | decK `wasm` plugin config with `path`/`regex_rules`/`state_store` fields | The Kong filter-chain schema is `{name, enabled, config}`; `path` lives on the discovered bundled-filter object; `regex_rules`/`state_store` are not Kong fields | The redaction plugin is now Lua (no Wasm schema involved). The custom Rust plugins' `config` shapes will be defined in each plugin's own `meta.json` `config_schema`. |
| 5 | `estimated_cost Float64` in ClickHouse | `Float64` aggregates are non-deterministic under ClickHouse MPP (`sum(toFloat64(0.45)) x 10000 = 4499.999...`); wrong for money. | `cost Decimal64(6)` + `rate_input`/`rate_output`/`currency` snapshot columns for audit-grade reproducibility. |
| 6 | "Sub-millisecond overhead / zero performance degradation" | Kong log-phase network I/O is already off-thread (`ngx.timer.at`), but broker backpressure spills into worker timer/connection exhaustion; synchronous Redis in access/rewrite is on-path and is not sub-millisecond. | Claim qualified: "off-request-thread, bounded by timer-pool capacity and broker ingest rate." Separate async-redaction branch (sidecar) explicitly avoids any on-path ML cost. |
| 7 | Kong faithfully records streamed token usage | Only an *estimate* when the provider omits usage. Open bugs: #14535 (streaming completion_tokens=0), #14816 (reasoning tokens not summed by Prometheus). Requires `stream_options.include_usage` + Kong >= 3.13 for real numbers; OTLP metrics need >= 3.14. | **Billing-grade contract**: enforce `stream_options.include_usage` on all streaming routes, pin Kong >= 3.14, add a daily **reconciler job** that cross-checks Kong logs against upstream provider billing APIs, and store per-rate snapshots. |

**Net architectural shift:** The Wasm/Rust layer no longer carries the redaction hot path;
it is now the implementation vehicle for the four *missing* Enterprise plugins (auth, failover,
semantic cache). The redaction hot path returns to Lua (industry precedent: Kong's own
`kong-plugin-argus-redact`, `ai-sanitizer` delegating to a sidecar).

---

## 1. Scope

This document specifies the **feasibility-corrected, OSS-only** architecture for a unified,
multi-tenant LLM Gateway built on **Kong Gateway Open Source (>= 3.14)** plus four custom
Rust Proxy-Wasm plugins (separately specified). It governs identity integration, per-user
virtual-token billing, PII anonymization/re-hydration, and edge intelligence (semantic cache,
adaptive failover).

**In scope:**
- Routing, auth, telemetry, and redaction data plane on free Kong.
- The interface contracts (header context, log schema, sidecar protocol) the custom Rust
  plugins must satisfy.
- Billing-grade token accounting with reconciliation.

**Out of scope (deferred to follow-up specs):**
- Internal implementation of the four custom Rust plugins
  (`PLUGIN-AUTH-OIDC`, `PLUGIN-AUTH-LDAP`, `PLUGIN-FAILOVER`, `PLUGIN-SEMANTIC-CACHE`).
- Hosting/operating the NER sidecar beyond its interface contract.

---

## 2. Terminology

| Term | Definition |
|------|-----------|
| Data Plane | The Kong gateway instance(s) executing request/auth/proxy/redaction logic. |
| Control Plane | decK-managed declarative config; no Kong DB-mode CP in this design (DB-less). |
| IdP | Identity Provider - Keycloak, Entra ID, or raw Active Directory (LDAP/Kerberos). |
| Context Pattern | Standardized `ngx.ctx` + header injection of `X-Tenant-ID`, `X-User-ID`, `X-Routing-Tier`. |
| PII Map | The per-stream `{placeholder -> original}` association used for re-hydration. |
| Sidecar NER | An out-of-process PII entity-recognition service invoked off the request thread. |
| Reconciler | A daily offline job cross-checking Kong usage logs against provider billing APIs. |

---

## 3. Architecture Overview

```
[ Inbound App Clients ]
        | (JWT / Bearer Token / Kerberos Service Ticket)
        v
+----------------------------------------------------------------+
| KONG AI DATA PLANE  (Kong Gateway OSS >= 3.14, DB-less)        |
|                                                                |
|  Phase 1: Unified Auth Engine                                 |
|    [PLUGIN-AUTH-OIDC]   cached-JWKS stateless JWT validation    |
|    [PLUGIN-AUTH-LDAP]   LDAP bind / Kerberos SPN against AD DC |
|    -> inject X-Tenant-ID / X-User-ID / X-Routing-Tier into ctx |
|                                                                |
|  Phase 2: PII Anonymization (Lua plugin - argus-redact pattern) |
|    Request:  fast Aho-Corasick regex + dict redaction, PII Map |
|              stashed in kong.ctx.plugin; heavy NER off-thread  |
|              via ngx.timer.at to Sidecar NER service.          |
|    Response: body_filter re-hydration from PII Map; cross-chunk|
|              sliding window; Content-Length cleared in header. |
|                                                                |
|  Phase 3: AI Proxy + Custom Routing                           |
|    [ai-proxy]      (OSS) canonical OpenAI format translation   |
|    [PLUGIN-FAILOVER]  weighted LB + 429/5xx mid-flight failover|
|    [PLUGIN-SEMANTIC-CACHE]  Redis VSS cosine cache (>= 95%)    |
|                                                                |
|  Log phase (off-thread, ngx.timer.at / kong.async):           |
|    emit ai.proxy.usage.* -> Vector -> ClickHouse + Prometheus  |
+----------------------------------------------------------------+
        | (Stripped PII + Per-target backend API key)
        v
[ Upstream Providers ]  (OpenAI / Azure / self-hosted vLLM / Bedrock)

[ Sidecar NER ]  <- off-thread from data plane; ONNX/Tract BERT-tiny
[ Redis ]        <- PII map durability (optional) + semantic cache VSS
[ ClickHouse ]   <- billing ledger
[ Prometheus ]   <- real-time alerts
```

---

## 4. Requirement 1 - Unified Multi-Identity Integration (Stateless Multi-IdP)

The gateway must authenticate OIDC (Keycloak/Entra) and legacy Windows/raw AD without an
internal user database and without the Kong Enterprise `openid-connect` / `ldap-auth`
plugins.

### 4.1 Two custom Rust Proxy-Wasm auth plugins

Because the Enterprise OIDC/LDAP plugins are excluded, **`PLUGIN-AUTH-OIDC`** and
**`PLUGIN-AUTH-LDAP`** are custom Rust Proxy-Wasm filters (specced in follow-up docs). They
must satisfy the following interface contract:

**`PLUGIN-AUTH-OIDC` (modern OIDC / OAuth2):**
- Stateless JWT validation against cached JWKS (refreshed on a TTL by `on_tick` via
  `dispatch_http_call` to the IdP `/.well-known/openid-configuration` + `/jwks` endpoint;
  cached in `set_shared_data` so it survives across streams/workers).
- Zero-roundtrip signature match on bearer tokens.
- Supports `bearer`, `client_credentials`, `refresh_token` grant surfaces required for
  machine-to-machine traffic.
- Emits the unified context headers (4.3).

**`PLUGIN-AUTH-LDAP` (legacy AD / Kerberos):**
- LDAP bind against the AD Domain Controller pool. **Constraint:** the Proxy-Wasm guest cannot
  open a TCP socket; therefore the bind call must be implemented as `dispatch_http_call` to an
  HTTP-fronted LDAP bridge (e.g. a thin REST gateway exposing `POST /ldap/bind`) OR the plugin
  acts purely as a Kerberos SPN token validator and delegates the actual bind to a small sidecar
  running alongside Kong. The follow-up spec must pick one and document the failure modes.
- Pulls `sAMAccountName`, group memberships (`memberOf`), and tenant partition attributes.
- Emits the unified context headers (4.3).

> **Note on `dispatch_http_call` semantics:** the call is asynchronous and callback-driven. The
> plugin MUST return `Action::Pause` from `on_http_request_headers` and call
> `resume_http_request` from `on_http_call_response`. Failure surfaces (bad pseudo-headers,
> missing upstream) return `BadArgument` / `InternalFailure` and must be handled explicitly -
> no silent fallthrough (Rule 13).

### 4.2 The Unified Context Pattern

Once either plugin succeeds, it injects standardized enterprise headers into `ngx.ctx` **and**
forwards them as request headers to upstream:

| Header | Source | Verification |
|--------|--------|--------------|
| `X-Tenant-ID` | tenant-partition claim / AD attribute | cryptographically bound to the verified token |
| `X-User-ID` | OIDC `sub` / AD `sAMAccountName` | set only by the auth plugin |
| `X-Routing-Tier` | group attribute (`Finance-PowerUsers`, `HR-Restricted`) | used by failover/cache plugins for tiered routing |

Downstream plugins (failover, cache, redaction, billing) read the context from `ngx.ctx`, never
re-validating identity. The headers are stripped before egress to upstream LLM providers
(redaction-side concern).

### 4.3 Strategic action item

Verify raw AD Domain Controllers expose LDAP endpoints or a Kerberos SPN target; confirm the
HTTP-fronted LDAP bridge (or Kerberos-only validation path) before plugin spec lock.

---

## 5. Requirement 2 - Per-User Virtual-Token Billing (Billing-Grade)

Tracking LLM workloads differs from API hit-counting: the gateway must isolate Inbound Prompt
Tokens, Outbound Completion Tokens, reasoning/cached token breakdowns, model SKU, and provider
cost grouped by user and tenant, with audit-grade reproducibility.

### 5.1 Telemetry pipeline

```
Kong log phase (log_by_lua, AFTER response sent)
     |
     | ai.proxy.usage.* assembled + kong.async dispatched
     v
Vector (tcp-log / http-log plugin sink)  --  Prometheus exporter (real-time alerts)
     |
     v
ClickHouse (columnar, TTL-partitioned billing ledger)
     |
     v
Reconciler (daily)  ->  compares ClickHouse to OpenAI/Azure usage APIs
```

### 5.2 Billing-grade contract (mandatory)

Because Kong's streamed usage extraction is unreliable by default (estimate mode; bugs #14535
streaming completion_tokens=0, #14816 reasoning tokens not summed), the gateway enforces:

1. **`stream_options.include_usage: true`** is injected by `PLUGIN-FAILOVER` on every streaming
   request to every provider that supports it (OpenAI/Azure do; vLLM must be configured per
   model). For providers that do not support it, the route is flagged `usage=estimate` and
   numbers carry a confidence flag in the ledger.
2. **Kong version pin: >= 3.14** (OTLP metrics with `gen_ai.client.token.usage` and
   `kong.gen_ai.llm.cost`; Prometheus `ai_llm_tokens_total` with `consumer` label since 3.11).
3. **Token breakdown stored separately** - `prompt_tokens`, `completion_tokens`,
   `reasoning_tokens`, `cached_tokens` - never summed into a single `total_tokens` for billing
   math (per bug #14816). `total_tokens` is stored only as the provider's reported value.
4. **Rate snapshots** - `rate_input`, `rate_output`, `currency`, `rate_model_name` are written
   at request time so a historical bill is reproducible after rates change.
5. **Reconciler job** - a daily offline process pulls the upstream provider billing APIs
   (OpenAI `/v1/usage`, Azure cost management) over the previous day and flags any divergence
   beyond a configurable tolerance per (tenant, provider, model, day). Divergence is emitted to
   the audit log and to ClickHouse `billing_discrepancies` table; it is never silently discarded
   (Rule 13).

### 5.3 ClickHouse schema (corrected)

```sql
CREATE TABLE llm_billing_ledger (
    event_id         String,                       -- kong.request.id
    tenant_id        LowCardinality(String),
    user_id          String,
    provider         LowCardinality(String),
    model_name       LowCardinality(String),
    route_name       LowCardinality(String),
    consumer_group   LowCardinality(String),       -- plan tier
    request_mode     LowCardinality(String),       -- oneshot / stream / realtime
    cache_status     LowCardinality(String),       -- hit / miss / bypass
    prompt_tokens    UInt32,
    completion_tokens UInt32,
    reasoning_tokens UInt32,
    cached_tokens    UInt32,
    total_tokens     UInt32,                       -- provider-reported, not summed
    rate_input       Decimal64(8),
    rate_output      Decimal64(8),
    currency         LowCardinality(String),
    cost             Decimal64(6),                 -- NOT Float64 - MPP-deterministic
    success          Bool,
    error_type       LowCardinality(String),
    llm_latency_ms   UInt32,
    ttft_ms          UInt32,                       -- time to first token (stream)
    upstream_resp_id LowCardinality(String),       -- provider x-request-id for disputes
    timestamp        DateTime64(3) DEFAULT now()
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (tenant_id, user_id, timestamp)
TTL timestamp + INTERVAL 13 MONTH
SETTINGS index_granularity = 8192;
```

Corrections vs v1.0:
- `cost Decimal64(6)` replaces `Float64` (Float64 yields non-deterministic aggregates under MPP;
  confirmed by ClickHouse own docs and Altinity).
- ORDER BY leads with low-cardinality filtering keys `(tenant_id, user_id, timestamp)` so
  per-tenant/per-user prefix pruning works; time column last for range scan and co-location.
- `PARTITION BY toYYYYMM(timestamp)` + `TTL ... 13 MONTH` for high-volume retention without
  `Too many parts`.
- Added audit columns required for dispute resolution and tiered billing: `event_id`,
  `upstream_resp_id`, `consumer_group`, `route_name`, `request_mode`, `cache_status`,
  `success`/`error_type`, `llm_latency_ms`, `ttft_ms`, per-type token breakdown, rate snapshots.

### 5.4 Performance claim (qualified)

Kong log-phase network I/O is **off the request thread** (cosockets are disabled in
`log_by_lua`); the plugin assembles the log record and enqueues it via `ngx.timer.at` /
`kong.async`. In-process enqueue is genuinely microsecond-scale, so "sub-millisecond data-plane
overhead" is plausible **for the enqueue step only**. The end-to-end (gateway -> Vector ->
ClickHouse) path is bounded by timer-pool/worker-connection capacity and Vector ingest rate; under
broker backpressure this spills into worker resource exhaustion and is **not** "zero degradation."
The reconciler tolerates eventual consistency but the data plane never blocks the client on it.

---

## 6. Requirement 3 - Real-Time PII Anonymization & Re-Hydration (Lua)

The v1.0 Rust-Wasm anonymizer failed feasibility on two fronts: (a) the Wasm guest cannot reach
Redis; (b) inline NER transformers block the single-threaded nginx worker. v2.0 reverts the
redaction hot path to a **Lua plugin** following the proven `kong-plugin-argus-redact` pattern,
with heavy NER pushed off-thread to a sidecar.

### 6.1 Redaction hot path (inline, Lua)

- Fast detection only: Aho-Corasick and a curated regex matrix for email, SSN, credit card,
  API keys, system tokens. Implemented in pure Lua (`lua-resty-aho-corasick` or a precompiled
  FFI matcher; paged dictionary for named-org entities).
- Original PII -> safe placeholder (e.g. `[CUSTOMER_NAME_1]`). The PII Map is stashed in
  `kong.ctx.plugin` (per-stream lifetime) - the simplest supported request->response coupling,
  no Redis needed for the hot path.
- `Content-Length` header is cleared in the `header_filter` phase (mandatory before entering
  `body_filter`; once headers are sent they cannot be reshaped).
- Cross-chunk sliding window: SSE responses stream as multiple chunks; a placeholder may span a
  chunk boundary. The Lua matcher keeps a tail buffer of `maxPlaceholderLen` bytes across
  `body_filter` invocations so partial placeholders are rehydrated correctly.

### 6.2 Heavy NER (off-thread sidecar)

Structural NER (Person/Org/Location) is beyond inline regex. It runs in a **Sidecar NER**
service (ONNX Runtime or Tract, BERT-tiny int8) co-located with the gateway, invoked
**off the request thread** via `ngx.timer.at` / `kong.async`:

1. The Lua plugin passes the needed text slice and a correlation id to the timer.
2. The timer POSTs to the sidecar's `POST /ner` endpoint and writes results to the PII Map in
   `kong.ctx.plugin`.
3. Re-hydration reads from the in-context PII Map; if the sidecar has not yet returned, the
   chunk waits or falls back to regex-only redaction for that segment.

> The data plane never blocks the client on the sidecar; the sidecar is best-effort enrichment
> layered on top of the fast inline regex guarantee.

### 6.3 Optional cross-worker PII Map durability

For retries across workers or long-running streams, the PII Map may be mirrored to Redis via
`lua-resty-redis` (host-side Lua, never inside Wasm). Keyed against a short-lived transaction
correlation ID with a TTL. This is strictly optional; the default is the per-stream context map.

### 6.4 Security guarantee

Upstream LLM providers never see original PII - only placeholders. PII is re-injected only as
the outbound stream passes back through the Lua `body_filter`. The PII Map never leaves the
gateway data plane (Redis, when used, is on the private cluster only).

### 6.5 Strategic action item

Compile the regex rules and dictionary profile(s) as a versioned artifact the Lua plugin loads
at init; benchmark the cross-chunk sliding window under realistic SSE chunk sizes before
declaring the re-hydration path production-ready.

---

## 7. Requirement 4 - Edge Intelligence (Custom Rust Plugins)

The `ai-semantic-cache` and `ai-proxy-advanced` plugins are Enterprise-only. Both capabilities
are rebuilt as custom Rust Proxy-Wasm plugins (specced separately).

### 7.1 `PLUGIN-SEMANTIC-CACHE` (Redis VSS)

- Vector similarity cache against Redis VSS (or pgvector). On a request, compute an embedding
  (model per route config; e.g. `text-embedding-3-large`), query Redis for nearest neighbor
  within a cosine threshold (configurable, default 0.95).
- Hit -> respond immediately from cache; record `cache_status=hit` in the billing ledger (no
  upstream token charge).
- Miss -> forward to Phase 3; on success cache the response keyed by the embedding.
- The embedding computation lives in a sidecar (HTTP) reachable via `dispatch_http_call`; the
  plugin never runs the embedding model in the Wasm guest.
- Tenant- and tier-scoped: `X-Tenant-ID` and `X-Routing-Tier` are part of the cache key so a hit
  in one tenant never leaks to another.

### 7.2 `PLUGIN-FAILOVER` (adaptive provider failover)

- Weighted multi-target routing across OpenAI / Azure / self-hosted vLLM / Bedrock, replacing
  Enterprise `ai-proxy-advanced`.
- Algorithm options: round-robin (weighted), least-connections, lowest-usage (by token cost),
  priority (tiered failover groups). The v1.0 "lowest-usage" strategy is real but only on the
  Enterprise plugin; the custom plugin replicates it.
- **Mid-flight failover on HTTP 429/5xx is opt-in**, configured via `failover_criteria`. For LLM
  chat (POST, non-idempotent), `non_idempotent` must be set or failover silently does not occur.
  Client errors (4xx except 429) never fail over by design.
- Enforces `stream_options.include_usage: true` on streaming requests to satisfy the
  billing-grade contract (5.2).
- Strips `X-Tenant-ID`/`X-User-ID`/`X-Routing-Tier` before egress to upstream providers.

### 7.3 Strategic action items

Capture the provider failover contract (algorithm choice, failover_criteria, retry/backoff,
circuit breaker thresholds) and the semantic-cache contract (embedding model, VSS distance
metric, TTL, tenant keying) in the two follow-up plugin specs before implementation begins.

---

## 8. Infrastructure as Code (GitOps / decK) - Revised Blueprint

The v1.0 decK blueprint used a fabricated `wasm` schema. The revised blueprint below uses only
the free Kong plugin surface (`jwt`, `key-auth`, the `ai-proxy` OSS plugin, `tcp-log`/`http-log`
for telemetry); the four custom plugins are placeholders pending their own specs and will be
loaded as bundled Proxy-Wasm filters discovered at startup via `wasm_filters_path`.

```yaml
_format_version: "3.0"
_transform: true

# Bundled custom Rust Proxy-Wasm filters are declared in kong.conf:
#   wasm_filters_path = /opt/kong/wasm
# Each filter ships an adjacent *.meta.json declaring its config_schema.

services:
  - name: enterprise-ai-cluster
    url: http://localhost:8001
    routes:
      - name: tenant-openai-endpoint
        paths:
          - "/v1/chat/completions"

        plugins:
          # Phase 1a: Identity - one of the two custom auth plugins per route.
          # (See PLUGIN-AUTH-OIDC / PLUGIN-AUTH-LDAP specs.)
          - name: auth-oidc                 # custom Rust Proxy-Wasm filter
            config:                          # shape per the filter's meta.json config_schema
              issuer: "https://identity.internal.firm/auth/realms/enterprise"
              jwks_ttl_seconds: 3600
              fail_open: false                # no silent fallback (Rule 13)

          # Phase 2: PII Anonymization - Lua plugin (argus-redact pattern).
          # Loaded via custom_lua_package / kong.plugins.redact -- not a Wasm filter.
          - name: redact
            config:
              regex_rules:
                - '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b'   # email
                - '\b\d{3}-\d{2}-\d{4}\b'                            # SSN
                - '\b(?:\d[ -]*?){13,16}\b'                          # card (loose)
              pii_map_strategy: ctx          # per-stream kong.ctx.plugin
              redis_mirror:                 # optional cross-worker durability
                enabled: false
                host: "redis-cluster.internal.net"
              ner_sidecar:
                url: "http://127.0.0.1:7999/ner"
                timeout_ms: 500
                fallback: regex_only         # never silent on sidecar failure (Rule 13)

          # Phase 3a: Semantic cache (custom Rust Proxy-Wasm filter).
          - name: semantic-cache
            config:
              vectordb:
                strategy: redis
                host: "redis-cluster.internal.net"
                distance_metric: cosine
                threshold: 0.95
                dimensions: 3072
              embedding:
                via: "dispatch_http_call"
                endpoint: "http://embedding-sidecar.internal.net/v1/embeddings"
                model: "text-embedding-3-large"
              ttl_seconds: 3600
              scope:                           # tenant + tier isolation
                - "X-Tenant-ID"
                - "X-Routing-Tier"

          # Phase 3b: Adaptive provider failover + format translation.
          - name: failover                 # custom Rust Proxy-Wasm filter
            config:
              force_stream_options: true      # billing-grade contract (5.2)
              strip_context_headers: true     # no PII/identity to upstream
              targets:
                - provider: openai
                  model: gpt-4o
                  auth_header_name: Authorization
                  auth_header_value: "Bearer {{vault:secret/ai/openai_key}}"
                  weight: 70
                - provider: azure
                  model: gpt-4
                  azure_instance: azure-us-east-node
                  azure_deployment_name: prod-deployment
                  auth_header_name: api-key
                  auth_header_value: "{{vault:secret/ai/azure_key}}"
                  weight: 30
              balancing:
                algorithm: lowest-usage
                failover_criteria:
                  - error
                  - timeout
                  - http_429
                  - http_502
                  - http_503
                  - http_504
                  - non_idempotent          # LLM chat is POST
                retries: 3
                circuit_breaker:
                  max_fails: 5
                  fail_timeout_seconds: 30

          # Telemetry (Kong OSS built-ins). Log-phase, off-request-thread.
          - name: http-log
            config:
              endpoint: "http://vector.internal.net:8080/ingest"
              method: POST
              content_type: application/json
              # The ai.proxy.usage.* fields are carried in the standard log body
              # (enabled on failover / ai-proxy via logging.log_statistics: true).
```

> The exact `config` shape of `auth-oidc`, `semantic-cache`, and `failover` is illustrative;
> the authoritative schemas will be defined in each plugin's `meta.json` `config_schema`
> (follow-up specs `PLUGIN-AUTH-*`, `PLUGIN-FAILOVER`, `PLUGIN-SEMANTIC-CACHE`).

---

## 9. Strategic Action Items

1. **Auth network topology** - Confirm raw AD Domain Controllers expose LDAP endpoints or a
   Kerberos SPN target; pick the LDAP bridge (HTTP-fronted `POST /ldap/bind` reached via
   `dispatch_http_call`) vs Kerberos-only validation path before `PLUGIN-AUTH-LDAP` spec lock.
2. **Pin Kong >= 3.14** across dev/staging/prod and verify OTLP metrics and Prometheus
   `ai_llm_tokens_total` `consumer` label behave as documented (open bugs #14535, #14816 to be
   regression-tested against this version).
3. **Redaction Lua plugin** - Port `kong-plugin-argus-redact` patterns (per-stream
   `kong.ctx.plugin` stash, `body_filter` rehydration, cross-chunk sliding window, `Content-Length`
   clear in header phase). Benchmark under realistic SSE chunk sizes.
4. **Sidecar NER service** - Stand up an ONNX/Tract BERT-tiny int8 service with a `POST /ner`
   endpoint behind `ngx.timer.at`; define the off-thread correlation protocol.
5. **ClickHouse pipeline** - Provision Vector to ingest `ai.proxy.usage.*` payloads; build daily
   billing aggregates and the **reconciler job** that cross-checks against OpenAI/Azure billing
   APIs.
6. **Custom plugin specs** - Open follow-up documents for `PLUGIN-AUTH-OIDC`,
   `PLUGIN-AUTH-LDAP`, `PLUGIN-FAILOVER`, `PLUGIN-SEMANTIC-CACHE`, each defining the Rust
   Proxy-Wasm implementation, `meta.json` `config_schema`, dispatch/async flow, and failure
   semantics (no silent fallback - Rule 13).

---

## 10. Open Questions Carried to Follow-Up Specs

| Question | Owner follow-up |
|----------|-----------------|
| LDAP bridge shape vs Kerberos-only validation | `PLUGIN-AUTH-LDAP` spec |
| `dispatch_http_call` pseudo-header / upstream-cluster requirements in `ngx_wasm_module` | each custom plugin spec |
| Embedding model choice and embedding-sidecar SLO for `PLUGIN-SEMANTIC-CACHE` | `PLUGIN-SEMANTIC-CACHE` spec |
| Circuit-breaker threshold defaults and retry semantics for `PLUGIN-FAILOVER` | `PLUGIN-FAILOVER` spec |
| vLLM `stream_options.include_usage` support matrix per model | billing-reconciler doc |
| PII Map TTL when Redis mirror is enabled | `PLUGIN-REDACT` (Lua) spec |

---

## 11. References

- Kong plugin tier frontmatter (`ai-proxy` OSS; `ai-proxy-advanced`/`ai-semantic-cache`/
  `openid-connect`/`ldap-auth` Enterprise): `docs.konghq.com/plugins/*`
- Kong OSS bundled-plugins list: `Kong/kong` `spec/01-unit/12-plugins_order_spec.lua`
- AI Gateway audit log reference (usage fields): `developer.konghq.com/ai-gateway/ai-audit-log-reference/`
- OpenTelemetry Gen AI spans (v3.13+) / OTLP metrics (v3.14+): `developer.konghq.com/ai-gateway/llm-open-telemetry/`, `developer.konghq.com/ai-gateway/ai-otel-metrics/`
- Streaming usage estimate caveat: `developer.konghq.com/ai-gateway/streaming/`
- Open bugs: `Kong/kong` issue #14535 (streaming completion_tokens=0), #14816 (reasoning tokens not summed)
- Kong log-phase cosocket restriction / async timers: `Kong/kong` discussions #7754, PR #6545
- Proxy-Wasm Rust SDK v0.2.5: `github.com/proxy-wasm/proxy-wasm-rust-sdk`; hostcalls (no socket): `docs.rs/proxy-wasm/latest/proxy_wasm/hostcalls/`
- `dispatch_http_call` async semantics: SDK issue #230 (must use dispatch, not reqwest-wasm), #137, #161 (Content-Length), #172 (pseudo-header trap)
- `ngx_wasm_module` (Kong-authored, not stock nginx): `github.com/Kong/ngx_wasm_module`
- Industry precedent - Lua redaction with `kong.ctx.plugin` + `body_filter`: `github.com/wan9yu/kong-plugin-argus-redact`
- Industry precedent - external PII service: `developer.konghq.com/plugins/ai-sanitizer/`
- ClickHouse Decimal vs Float for money: `clickhouse.com/docs/sql-reference/data-types/float`, `kb.altinity.com/altinity-kb-schema-design/floats-vs-decimals/`
- ClickHouse partitioning/ordering best practices: `clickhouse.com/docs/best-practices/choosing-a-partitioning-key`

---

**End of document.**