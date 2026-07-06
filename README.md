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

A single-route LLM gateway that relays requests to OpenCode Zen
(`https://opencode.ai/zen/v1`), providing:

- **PII anonymization and re-hydration** in pure Lua (`ngx.re` PCRE).
  PII never reaches the upstream LLM. Regex + file-based dictionary
  detection with Luhn validation for credit cards.
- **Key-based authentication** via APISIX built-in `key-auth` plugin.
- **Per-model rate limiting** via APISIX built-in `ai-rate-limiting`.
- **Telemetry logging** via `http-logger` to Vector to ClickHouse
  (`request_log` table with token usage capture).
- **Prometheus metrics** endpoint at `/apisix/prometheus/metrics`.
- **Billing-grade schema** in ClickHouse (`request_log`,
  `billing_ledger`, `billing_discrepancies`) with Decimal64(6) for
  cost, 13-month TTL, low-cardinality ORDER BY keys.

The data plane runs on Apache APISIX 3.17.0
(`apache/apisix:3.17.0-debian`). All plugins are OSS, no license
enforcement, no tier split. Standalone YAML mode provides file-driven
hot reload with no etcd or PostgreSQL needed.

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
├── Makefile                       # lint, type-check, test, check targets
├── pyproject.toml                 # podman-compose dependency
├── ci-profile.yaml                # CI configuration profile
├── .gitignore
├── docs/                          # architecture & plugin specifications
│   ├── README.md                  # docs index + reading order
│   ├── TEST-PLAN.md               # 6-stage test plan + audit findings
│   ├── PROPOSAL-LLM-GATEWAY-v3.md # umbrella architecture
│   ├── PLUGIN-FOUNDATION.md       # APISIX custom Lua plugin dev foundation
│   ├── BUILTIN-PLUGINS.md         # APISIX built-in plugin config guide
│   ├── PLUGIN-REDACT-LUA.md       # custom Lua: regex + dict PII redaction (v1)
│   ├── PLUGIN-REDACT-ENGINE.md    # optional Rust NER sidecar (v2)
│   ├── PLUGIN-SEMANTIC-CACHE.md   # custom Lua: Redis VSS semantic cache (v2)
│   ├── DEPLOYMENT.md              # deployment guide
│   └── OPENCODE-INTEGRATION.md    # OpenCode Zen integration specifics
├── plugins/
│   └── custom/
│       ├── redact_lib.lua         # pure logic module (requireable, testable)
│       └── redact.lua             # APISIX plugin adapter (lifecycle)
├── conf/
│   ├── config.yaml                # APISIX config (standalone YAML mode)
│   ├── apisix.yaml                # routes + plugin configs
│   ├── redact-patterns.json       # PII regex + dictionary
│   ├── clickhouse-init.sql        # ClickHouse schema
│   └── vector.toml                # telemetry pipeline config
├── res/
│   ├── docker/
│   │   ├── docker-compose.yml
│   │   └── Dockerfile.apisix
│   └── scripts/
│       └── reconciler.sh          # daily billing reconciler
├── tests/
│   ├── lua/                       # Stage 1: Lua unit tests
│   ├── config/                    # Stage 2: Config validation
│   ├── reconciler/                # Stage 3: Reconciler static tests
│   ├── integration/               # Stage 4: Podman stack integration
│   ├── ci/                        # Stage 5: CI hook verification
│   ├── e2e/                       # Stage 6: End-to-end Zen API
│   └── run_all.sh                 # master test runner
└── config/
    └── coverage_thresholds.yaml   # CI coverage config
```

---

## Architecture (high-level)

```
[ Inbound App Clients ]
        |  (apikey header for gateway auth)
        v
+----------------------------------------------------------------+
| APISIX AI DATA PLANE  (Apache APISIX 3.17.0, standalone YAML)  |
|                                                                |
|  Phase 1: Authentication (built-in plugin)                    |
|    key-auth          shared-key consumer validation            |
|                                                                |
|  Phase 2: PII Anonymization (custom Lua plugin, v1)           |
|    redact   ngx.re PCRE + file-based dictionary                |
|             PII Map stashed in ctx (per-request)               |
|             response: body_filter re-hydration (local gsub)    |
|             patterns cached in shared dict (60s TTL)          |
|                                                                |
|  Phase 3: Rate Limiting + Proxy (built-in plugins)            |
|    ai-rate-limiting  per-model request count limits            |
|    proxy-buffering   disabled per-route for SSE                |
|                                                                |
|  Log phase:                                                   |
|    http-logger  -> Vector -> ClickHouse (request_log)          |
|    prometheus   -> /apisix/prometheus/metrics                  |
+----------------------------------------------------------------+
        |  (Redacted body + Authorization: Bearer Zen key)
        v
[ OpenCode Zen ]  (https://opencode.ai/zen/v1)

[ ClickHouse ]      <- request_log + billing schema
[ Vector ]          <- telemetry ingest (HTTP to ClickHouse)
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

## Billing and telemetry

The gateway captures token usage from LLM responses and logs it to
ClickHouse via Vector:

1. `http-logger` sends request metadata + request/response bodies to
   Vector (response body limited to 8KB).
2. Vector's remap transform extracts `model`, `stream` from the
   request body and `prompt_tokens`, `completion_tokens`,
   `total_tokens` from the response body's `usage` object.
3. Vector writes the enriched event to ClickHouse `request_log`
   table.
4. Daily reconciler (`res/scripts/reconciler.sh`) queries
   `request_log` for gateway-side token totals. Upstream provider
   API comparison is v2.

ClickHouse schema uses `Decimal64(6)` for `cost` in `billing_ledger`
(NOT `Float64`), `PARTITION BY toYYYYMM(timestamp)`, TTL 13 months,
`ORDER BY (provider, model, timestamp)` for prefix-pruned queries.

---

## Status

**Phase: v1 implementation complete, testing in progress.**

v1 scope (implemented):
- Custom Lua redact plugin (`redact.lua` + `redact_lib.lua`) with
  regex + dictionary PII detection, Luhn validation, per-request
  token map, response re-hydration
- APISIX standalone YAML config with `key-auth`, `ai-rate-limiting`,
  `prometheus`, `http-logger`, `proxy-buffering`, `redact` plugins
- Single route relay to OpenCode Zen (`/zen/*` to `opencode.ai:443`)
- ClickHouse billing schema (`request_log`, `billing_ledger`,
  `billing_discrepancies` tables)
- Vector telemetry pipeline (HTTP ingest to ClickHouse)
- Docker compose stack (APISIX, ClickHouse, Vector)
- 6-stage test suite (Lua unit, config validation, reconciler,
  integration, CI hooks, E2E with real Zen API)
- Daily reconciler script (gateway totals logging; upstream
  comparison is v2)

v2 scope (deferred):
- Semantic cache plugin (`semantic-cache.lua`)
- NER sidecar (`ner-engine` Rust binary)
- Embedding service (`embedding-service` Rust binary)
- Multi-provider failover (`ai-proxy-multi`)
- OIDC/LDAP authentication
- Upstream billing API reconciliation

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
**Last updated:** 2026-07-06
**Document set version:** v3.0 (APISIX, supersedes v2.0 Kong architecture)
