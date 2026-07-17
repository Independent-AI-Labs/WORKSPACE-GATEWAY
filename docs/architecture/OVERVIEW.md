# System Overview

**Date:** 2026-07-17

WORKSPACE-GATEWAY is a multi-tenant LLM gateway on **Apache APISIX 3.17.0**
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

## Routes (10)

Defined in [`conf/apisix.yaml`](../../conf/apisix.yaml), grouped by upstream.

### opencode relay (`opencode.ai:443`, rewrite to `/zen/go/`)

| Route id | Prefix | Auth |
|----------|--------|------|
| `relay-opencode` | `/opencode/*` | Direct key passthrough (`key-meta`) |
| `relay-opencode-federated` | `/opencode_federated/*` | `vgw-*` via `key-resolver` + OpenBao |

### Kimi (`api.kimi.com:443`, rewrite to `/coding/v1/`)

| Route id | Prefix | Auth |
|----------|--------|------|
| `relay-kimi` | `/kimi/*` | `kimi-auth` OAuth device flow |
| `relay-kimi-v1` | `/kimi/v1/*` | `kimi-auth` |
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
| `kimi-auth` | Kimi OAuth device-code auth and token lifecycle |
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
| `kimi_device.lua` / `kimi_jwt.lua` / `kimi_tokens.lua` | `kimi-auth` |

## Built-in plugins (on routes)

`proxy-rewrite`, `limit-count`, `prometheus`, `request-id`, `http-logger`,
`proxy-buffering`. `ai-rate-limiting` is registered but not enabled on any
route.

## Next

- Runtime: [`RUNTIME-TOPOLOGY.md`](RUNTIME-TOPOLOGY.md)
- Plugins: [`PLUGIN-PIPELINE.md`](PLUGIN-PIPELINE.md),
  [`CUSTOM-PLUGINS.md`](CUSTOM-PLUGINS.md)
