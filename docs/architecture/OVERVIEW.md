# System Overview

WORKSPACE-GATEWAY is a multi-tenant LLM gateway on **Apache APISIX 3.17.0**
(traditional/etcd mode). Four registered custom Lua plugins plus
`cost_calc.lua` (shared library), six built-in plugins on the hot path,
OpenBao virtual keys, PII redaction, billing-grade ClickHouse accounting,
and Prometheus metrics.

**Zero sidecars on the request path.** All request-time logic runs in pure
Lua inside the APISIX Nginx worker.

## Deployment mode

Routes and global config live in **etcd**, not a standalone YAML data plane.

1. [`conf/apisix.yaml.j2`](../../conf/apisix.yaml.j2) rendered to
   [`conf/apisix.yaml`](../../conf/apisix.yaml) at deploy (Ansible + `.env`)
2. [`res/scripts/seed-routes.sh`](../../res/scripts/seed-routes.sh) seeds etcd
   on stack start
3. Admin API and built-in UI at `http://localhost:9180/ui/` (`${{ADMIN_KEY}}`)

See [`README.md` Configuration](../../README.md#routes-and-config-control-plane)
for the control-plane diagram.

## Routes (3)

| Route id | Prefix | Auth | Sample upstream |
|----------|--------|------|-----------------|
| `relay-opencode` | `/opencode/*` | Direct key passthrough | OpenCode Go -> `/zen/go/*` |
| `relay-opencode-federated` | `/opencode_federated/*` | `vgw-*` via OpenBao | OpenCode Go -> `/zen/go/*` |
| `relay-llamafile` | `/llamafile/*` | None (local dev) | VM llamafile |

Full sample table: [`README.md` Sample deployments](../../README.md#sample-deployments-in-this-repo).

The gateway is **provider-agnostic**. OpenCode Go is the sample cloud
upstream in this repo; swap `nodes` in the J2 template or add relay routes
for any OpenAI-compatible API. Built-in `ai-proxy` / `ai-proxy-multi` are
alternatives (see [`BUILTIN-PLUGINS.md`](../BUILTIN-PLUGINS.md)).

## Custom plugins

| Plugin | Role |
|--------|------|
| `key-resolver` | Virtual keys via OpenBao; passthrough for non-`vgw-` |
| `key-meta` | `X-Key-Hash` for per-key scoping |
| `redact` | PII anonymize + re-hydrate |
| `sse-usage` | SSE/JSON token extraction; usage_log INSERT |
| `cost_calc` | Library: pricing, `normalize_key` (not registered) |

## Built-in plugins (on routes)

`proxy-rewrite`, `limit-count`, `prometheus`, `request-id`, `http-logger`,
`proxy-buffering`. Federated route adds `key-resolver`.

`ai-rate-limiting` is registered in [`conf/config.yaml`](../../conf/config.yaml)
but not enabled on any route.

## Next

- Runtime: [`RUNTIME-TOPOLOGY.md`](RUNTIME-TOPOLOGY.md)
- Plugins: [`PLUGIN-PIPELINE.md`](PLUGIN-PIPELINE.md)