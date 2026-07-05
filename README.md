# WORKSPACE-GATEWAY

High-performance, enterprise, multi-tenant **LLM Gateway** built on
**Apache APISIX 3.17.0** (standalone YAML mode, Apache 2.0, all plugins OSS),
with one custom Lua plugin (redaction) in v1 and a second (semantic cache) in v2.
Auth, failover, rate-limiting, AI proxy, and telemetry are APISIX built-in plugins
, zero custom code.

> Part of the `Independent-Ai-Labs/WORKSPACE-VM` monorepo.
> Live spec docs in [`docs/`](docs/README.md). Implementation land is open.

---

## What this is

A single fault-tolerant edge that fronts OpenAI, Azure OpenAI, AWS Bedrock,
Anthropic, and self-hosted vLLM and provides:

- **Multi-IdP authentication**, OIDC/OAuth2 (Keycloak, Entra ID) and LDAP
  Windows Active Directory. APISIX built-in `openid-connect` and `ldap-auth`
  plugins. Zero user-directory sync.
- **Per-user, per-tenant virtual token billing**, audit-grade, billing-reconciled
  against upstream provider APIs. Streaming-safe via enforced
  `stream_options.include_usage`.
- **Real-time PII anonymization & re-hydration**, regex + file-based dictionary
  detection in pure Lua (`ngx.re` PCRE). PII never reaches upstream LLM providers.
  Optional NER sidecar (v2) for named-entity detection.
- **Semantic cache** (v2), Redis VSS similarity lookup via `lua-resty-redis`
  cosocket. Cache hits skip upstream cost.
- **Adaptive multi-provider failover**, weighted load balancing, priority groups,
  fallback strategies, retries, health checks. APISIX built-in `ai-proxy-multi`.

The data plane runs on **Apache APISIX 3.17.0** (`apache/apisix:3.17.0-debian`).
All plugins are OSS, no license enforcement, no tier split, no Enterprise image.
Standalone YAML mode provides file-driven hot reload with no etcd or PostgreSQL
needed for gateway config.

---

## Why APISIX (not Kong)

The v2.0 architecture used Kong Gateway 3.14 (Enterprise image, unlicensed) with
four custom Rust Proxy-Wasm plugins. Deep research revealed:

- Kong 3.14 Enterprise code is private; 3.14 was never tagged on GitHub.
- Free mode is deprecated (3.10) and **removed** in 3.15.
- `openid-connect`, `ldap-auth-advanced`, `ai-proxy-advanced`, `ai-semantic-cache`
  are all Enterprise-only.
- Custom Rust Wasm requires `wasm32-wasip1` toolchain, `dispatch_http_call` async
  state machines, no socket access in the guest.

APISIX resolves all of this: Apache 2.0, all plugins OSS, source fully public,
Docker images for every version. The pivot reduces **5 custom plugin
implementations to 2 custom Lua plugins** and eliminates the Rust Wasm toolchain
entirely. See [`docs/PROPOSAL-LLM-GATEWAY-v3.md`](docs/PROPOSAL-LLM-GATEWAY-v3.md)
§0 for the full rationale.

---

## Repository layout

```
WORKSPACE-GATEWAY/
├── README.md                      # this file
├── docs/                          # architecture & plugin specifications
│   ├── README.md                  # docs index + reading order
│   ├── PROPOSAL-LLM-GATEWAY-v3.md # umbrella architecture (supersedes v2)
│   ├── PLUGIN-FOUNDATION.md       # APISIX custom Lua plugin dev foundation
│   ├── BUILTIN-PLUGINS.md         # APISIX built-in plugin config guide
│   ├── PLUGIN-REDACT-LUA.md       # custom Lua: regex + dict PII redaction (v1)
│   ├── PLUGIN-REDACT-ENGINE.md    # optional Rust NER sidecar (v2)
│   ├── PLUGIN-SEMANTIC-CACHE.md   # custom Lua: Redis VSS semantic cache (v2)
│   └── DEPLOYMENT.md              # docker-compose, config, ClickHouse, Vector
├── plugins/                       # (created at implementation time)
│   └── custom/
│       ├── redact.lua             # v1 custom plugin
│       └── semantic-cache.lua     # v2 custom plugin
├── conf/                          # (created at implementation time)
│   ├── config.yaml                # APISIX config (standalone YAML mode)
│   ├── apisix.yaml                # routes + plugin configs
│   ├── redact-patterns.json       # PII regex + dictionary
│   ├── clickhouse-init.sql        # billing ledger schema
│   └── vector.toml                # telemetry pipeline config
├── res/
│   ├── docker/
│   │   ├── docker-compose.yml
│   │   └── Dockerfile.apisix
│   ├── scripts/
│   │   └── reconciler.sh          # daily billing reconciler
│   └── LOGO_RAW.png
└── sidecars/                      # (v2)
    ├── ner-engine/                # Rust binary, ONNX BERT-tiny
    └── embedding-service/         # Rust binary, torch/llama.cpp
```

---

## Architecture (high-level)

```
[ Inbound App Clients ]
        |  (JWT / Bearer / LDAP credentials)
        v
+----------------------------------------------------------------+
| APISIX AI DATA PLANE  (Apache APISIX 3.17.0, standalone YAML)  |
|                                                                |
|  Phase 1: Unified Auth (built-in plugins)                     |
|    openid-connect   cached-JWKS JWT validation (Keycloak/Entra)|
|    ldap-auth         LDAP bind against AD DC                   |
|    -> injects X-Tenant-ID / X-User-ID / X-Routing-Tier         |
|                                                                |
|  Phase 2: PII Anonymization (custom Lua plugin, v1)           |
|    redact   ngx.re PCRE + file-based dictionary                |
|             PII Map stashed in ctx (per-request)               |
|             response: body_filter re-hydration (local gsub)    |
|             v2: NER sidecar via ngx.timer.at (off-thread)      |
|                                                                |
|  Phase 3: AI Proxy + Routing (built-in plugins)               |
|    semantic-cache   Redis VSS cosine cache (v2, custom Lua)    |
|    ai-proxy-multi   weighted LB + failover + retry             |
|    ai-proxy         provider format translation                |
|    ai-rate-limiting per-consumer, per-model token limits       |
|    proxy-buffering  disabled per-route for SSE                 |
|                                                                |
|  Log phase (off-thread, ngx.timer.at):                        |
|    http-logger  -> Vector -> ClickHouse (billing ledger)       |
|    prometheus   -> real-time alerts                            |
+----------------------------------------------------------------+
        |  (Stripped PII + Per-target API key)
        v
[ Upstream Providers ]  (OpenAI / Azure / Bedrock / Anthropic / vLLM)

[ Redis 8 (VSS) ]   <- semantic cache vectors (v2)
[ ClickHouse ]      <- billing ledger
[ Vector ]          <- telemetry ingest
[ Keycloak ]        <- OIDC IdP (from DATAOPS)
```

---

## Plugin mapping: Kong Enterprise to APISIX

| Kong Enterprise plugin | APISIX replacement | Custom code? |
|------------------------|-------------------|--------------|
| `openid-connect` | Built-in `openid-connect` | No, config only |
| `ldap-auth-advanced` | Built-in `ldap-auth` / `forward-auth` | No, config only |
| `ai-proxy-advanced` | Built-in `ai-proxy-multi` | No, config only |
| `ai-semantic-cache` | Custom Lua `semantic-cache` (v2) | Yes, Lua plugin |
| `ai-proxy` (OSS) | Built-in `ai-proxy` | No, config only |
| Rate limiting | Built-in `ai-rate-limiting` | No, config only |
| Telemetry | Built-in `http-logger` + `prometheus` | No, config only |
| SSE buffering | Built-in `proxy-buffering` | No, config only |
| PII redaction (no Kong equivalent) | Custom Lua `redact` (v1) | Yes, Lua plugin |

**5 custom plugin implementations reduced to 2.** No Rust Wasm. No
`dispatch_http_call`. No `meta.json` Draft-4 schemas.

---

## Sidecar inventory

| Sidecar | Version | Listens on | Purpose |
|---------|---------|-----------|---------|
| (none) | v1 | N/A | All hot-path logic in pure Lua; auth/failover/rate-limit built-in |
| `ner-engine` | v2 | `127.0.0.1:8081` | Rust binary, ONNX BERT-tiny, `POST /ner` (off-thread enrichment) |
| `embedding-service` | v2 | `127.0.0.1:8090` | Rust binary, torch/llama.cpp, `POST /v1/embeddings` (local model) |

**v1 has zero sidecars.** The entire gateway is APISIX + Redis + ClickHouse +
Vector, all configured via YAML.

---

## Billing-grade contract

Per [`docs/PROPOSAL-LLM-GATEWAY-v3.md`](docs/PROPOSAL-LLM-GATEWAY-v3.md) §6.2, the
gateway enforces:

1. `stream_options.include_usage: true` on every streaming route (via `ai-proxy`
   config or Lua glue plugin).
2. Token breakdown stored separately (`prompt_tokens`, `completion_tokens`,
   `reasoning_tokens`, `cached_tokens`), never summed for billing math.
3. **Rate snapshots** stored at request time for reproducible historical bills.
4. **Daily reconciler job** cross-checks ClickHouse ledger against OpenAI/Azure
   usage APIs; divergence flagged to `billing_discrepancies` table, never silently
   dropped.

ClickHouse schema uses `Decimal64(6)` for `cost` (NOT `Float64`, MPP aggregates
non-deterministic with floats), `PARTITION BY toYYYYMM(timestamp)`, TTL 13 months,
`ORDER BY (tenant_id, user_id, timestamp)` for prefix-pruned per-tenant queries.

---

## Status

**Phase: specification complete, implementation not started.**

All seven specs in `docs/` are research-validated drafts with config examples,
failure-mode tables, test plans, and open questions. v1 scope: redaction plugin +
built-in plugin configuration + deployment. v2 scope: semantic cache + NER sidecar
+ embedding sidecar.

Implementation begins once the specs land stakeholder review signoff; per-plugin
specs each define their own test plan that must pass before merge (no `#[allow]` /
no silent fallback per the workspace `AGENTS.md` rules).

---

## Reading order

1. [`docs/PROPOSAL-LLM-GATEWAY-v3.md`](docs/PROPOSAL-LLM-GATEWAY-v3.md), revised
   umbrella architecture & rationale.
2. [`docs/PLUGIN-FOUNDATION.md`](docs/PLUGIN-FOUNDATION.md), shared APISIX plugin
   development contracts.
3. [`docs/BUILTIN-PLUGINS.md`](docs/BUILTIN-PLUGINS.md), built-in plugin
   configuration (auth, proxy, failover, telemetry).
4. [`docs/PLUGIN-REDACT-LUA.md`](docs/PLUGIN-REDACT-LUA.md), the v1 custom plugin.
5. [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md), how to deploy and operate.
6. v2 specs: [`docs/PLUGIN-SEMANTIC-CACHE.md`](docs/PLUGIN-SEMANTIC-CACHE.md),
   [`docs/PLUGIN-REDACT-ENGINE.md`](docs/PLUGIN-REDACT-ENGINE.md).

---

## License posture

- **Apache APISIX 3.17.0**, Apache 2.0. ALL plugins OSS, no license enforcement,
  no tier split. Source code public. Docker images for every version.
- **Custom Lua plugins** are bespoke, written for this project.
- **Rust sidecars** (v2): `ort` (ONNX Runtime, MIT), `axum` (MIT), `tokenizers`
  (Apache 2.0). All dependencies MIT or Apache-2.0.
- No Kong, no Wasm, no Proxy-Wasm, no Enterprise licensing concerns.

---

## References

- Apache APISIX: https://apisix.apache.org/
- APISIX plugin development: https://apisix.apache.org/docs/apisix/plugin-develop/
- APISIX standalone mode: https://apisix.apache.org/docs/apisix/deployment-modes/
- APISIX `openid-connect`: https://apisix.apache.org/docs/apisix/plugins/openid-connect/
- APISIX `ai-proxy` / `ai-proxy-multi`: https://apisix.apache.org/docs/apisix/plugins/ai-proxy/
- APISIX `ai-rate-limiting`: https://apisix.apache.org/docs/apisix/plugins/ai-rate-limiting/
- APISIX `proxy-buffering` (PR #13446, 3.17.0): https://github.com/apache/apisix/pull/13446
- Redis VSS: https://redis.io/docs/latest/develop/ai/search-and-query/vectors/
- ClickHouse Decimal vs Float: https://clickhouse.com/docs/sql-reference/data-types/float
- OpenResty cosocket phases: https://github.com/openresty/lua-nginx-module#cosockets
- `lua-resty-http`: https://github.com/ledgetech/lua-resty-http
- `lua-resty-redis`: https://github.com/openresty/lua-resty-redis

---

**Maintained by:** AMI-Agents Engineering
**Last updated:** 2026-07-05
**Document set version:** v3.0 (APISIX, supersedes v2.0 Kong architecture)
