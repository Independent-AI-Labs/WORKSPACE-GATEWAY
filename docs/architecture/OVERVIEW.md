# System Overview

**Date:** 2026-07-17

WORKSPACE-GATEWAY is a multi-tenant LLM gateway on **Apache APISIX 3.18.0**
(traditional/etcd mode). Six registered custom Lua plugins plus shared Lua
library modules, OpenBao virtual keys, Kimi OAuth device auth, PII redaction,
billing-grade ClickHouse accounting, and Prometheus metrics.

**Zero sidecars on the request path.** All request-time logic runs in pure
Lua inside the APISIX Nginx worker.

## Deployment mode

`conf/config.yaml` sets `role: traditional`, `config_provider: etcd`.
Routes and global config live in **etcd**, not a standalone YAML data plane.
[`conf/apisix.yaml`](../../conf/apisix.yaml) is the seed document pushed to
etcd at deploy.

## Routes (18)

Defined in [`conf/apisix.yaml`](../../conf/apisix.yaml), grouped by upstream.

### opencode relay (`opencode.ai:443`)

| Route id | Prefix | Rewrite | Auth |
|----------|--------|---------|------|
| `relay-opencode` | `/opencode/*` | `/zen/go/$1` | Direct key passthrough (`key-meta`) |
| `relay-opencode-federated` | `/opencode_federated/*` | `/zen/go/$1` | `vgw-*` via `key-resolver` + OpenBao |
| `relay-opencode-zen` | `/opencode_zen/*` | `/zen/$1` | Direct key passthrough (`key-meta`) |

### OpenAI (`chatgpt.com:443`, rewrite to `/backend-api/codex/responses`)

| Route id | Prefix | Auth |
|----------|--------|------|
| `relay-openai` | `/openai/*` | OpenAI ChatGPT headless OAuth (`provider-oauth`) |

### Anthropic (`api.anthropic.com:443`, rewrite to `/$1`)

| Route id | Prefix | Auth |
|----------|--------|------|
| `relay-anthropic` | `/anthropic/*` | None (bare passthrough) |
| `relay-anthropic-device` | `/anthropic-device/*` | Custodial device facade (`provider-oauth`) |

### Z.ai (`api.z.ai:443`, rewrite to `/api/coding/paas/v4/`)

| Route id | Prefix | Auth |
|----------|--------|------|
| `relay-zai-key` | `/zai-key/*` | Direct key passthrough (`key-meta`) |
| `relay-zai-key-v1` | `/zai-key/v1/*` | Direct key passthrough (`key-meta`) |

### Alibaba Token Plan (rewrite to `/$1`)

| Route id | Prefix | Auth |
|----------|--------|------|
| `relay-alibaba-token-plan` | `/token-plan/*` | Direct key passthrough (`key-meta`), International |
| `relay-alibaba-token-plan-cn` | `/token-plan-cn/*` | Direct key passthrough (`key-meta`), China |

### Kimi (`api.kimi.com:443`, rewrite to `/coding/v1/`)

| Route id | Prefix | Auth |
|----------|--------|------|
| `relay-kimi` | `/kimi/*` | `provider-oauth` OAuth device flow |
| `relay-kimi-v1` | `/kimi/v1/*` | `provider-oauth` |
| `relay-kimi-federated` | `/kimi-federated/*` | `key-resolver` + OpenBao |
| `relay-kimi-federated-v1` | `/kimi-federated/v1/*` | `key-resolver` + OpenBao |
| `relay-kimi-key` | `/kimi-key/*` | Direct key passthrough (`key-meta`) |
| `relay-kimi-key-v1` | `/kimi-key/v1/*` | Direct key passthrough (`key-meta`) |

### llamafile (`host.docker.internal:8765`, rewrite to `/`)

| Route id | Prefix | Auth |
|----------|--------|------|
| `relay-llamafile` | `/llamafile/*` | None; per-IP `limit-count` (600/min) |

### provider-sync (served in-worker, `127.0.0.1:9080`)

| Route id | Prefix | Auth |
|----------|--------|------|
| `gateway-provider-sync` | `/gateway/providers*` | `provider-sync` serves API directly |

## Custom plugins (6 registered)

Registered in `conf/config.yaml`:

| Plugin | Role |
|--------|------|
| `key-resolver` | Virtual keys via OpenBao; passthrough for non-`vgw-` |
| `key-meta` | `X-Key-Hash` header for per-key `limit-count` scoping |
| `provider-oauth` | OAuth device-code auth and token lifecycle (Kimi, OpenAI, Anthropic) |
| `provider-sync` | Read-only `/gateway/providers` catalog + pricing API |
| `sse-usage` | SSE/JSON token extraction; ClickHouse `usage_log` INSERT |
| `redact` | PII anonymize + re-hydrate |

## Lua library modules (not registered plugins)

| Module | Consumer |
|--------|----------|
| `cost_calc.lua` | `sse-usage`  -  `get_pricing` / `compute_cost` / `resolve_cost` (read-only) |
| `model_registry.lua` | Codegenned from `conf/model-registry.yaml`; canonical model ids |
| `provider_sync_catalog.lua` | `provider-sync`  -  provider/model catalog |
| `provider_sync_pricing.lua` | `provider-sync`  -  sole writer of `pricing:*` in `gateway-cache` |
| `sse_usage_lib.lua` | `sse-usage` pure logic core |
| `redact_lib.lua` | `redact` pure logic core |
| `oauth_device.lua` / `oauth_jwt.lua` / `oauth_store.lua` | `provider-oauth` |

## Built-in plugins (on routes)

`proxy-rewrite`, `limit-count`, `prometheus`, `request-id`, `http-logger`,
`proxy-buffering`. `ai-rate-limiting` is registered but not enabled on any
route.

## Next

- Runtime: [`RUNTIME-TOPOLOGY.md`](RUNTIME-TOPOLOGY.md)
- Plugins: [`PLUGIN-PIPELINE.md`](PLUGIN-PIPELINE.md),
  [`CUSTOM-PLUGINS.md`](CUSTOM-PLUGINS.md)
