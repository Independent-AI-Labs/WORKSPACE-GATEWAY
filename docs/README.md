# LLM Gateway Documentation

**Project:** WORKSPACE-GATEWAY, High-Performance Enterprise Multi-Tenant LLM Gateway
**Platform:** Apache APISIX 3.17.0 (traditional/etcd mode)
**Status:** Implementation complete; audit findings tracked per-document
**Date:** 2026-07-13 (revised)

## Audit Context

A full audit (2026-07-09) found that several documents describe aspirational
or outdated behavior. Every document carries a `KNOWN ISSUES` block at its
head listing discrepancies between documentation and observed reality.
Subsequent commits (through 2026-07-13) addressed deployment mode (etcd),
llamafile routing, Grafana dashboards, correlation ID / event_id tests, and
the `workspace-gw-llamafile` opencode provider. Key cross-cutting findings
that remain open:

- **`docs/architecture/README.md`**: Architecture hub and child docs (ALL_CAPS). Read this first.
- **`docs/DASHBOARD-REQUIREMENTS.md`**: Panels 8/10 ASOF JOINs are
  probabilistically wrong; event_id JOIN doesn't work historically.
- **`docs/COST-CALC-LUA.md`**: Cost calc module is correct; CJK token
  estimation in feeding function undercounts by ~25% (unit tests exist;
  accuracy gap remains).
- **`docs/TEST-PLAN.md`**: R-41-R-46 partially addressed; concurrent-request
  and Vector backpressure gaps remain.

Documents with partial staleness (standalone YAML references, pre-etcd wording):
`PROPOSAL-LLM-GATEWAY-v3.md`, `PLUGIN-FOUNDATION.md`, `DEPLOYMENT.md`.
`OPENCODE-INTEGRATION.md` and `DASHBOARD-REQUIREMENTS.md` were updated in
the 2026-07-12/13 dashboard and provider work.

## Index

| Document | Scope |
|----------|-------|
| [`architecture/README.md`](architecture/README.md) | Architecture hub: components, plugins, data flows, schema, scripts, tests. Audit gaps in [`OPEN-ISSUES.md`](architecture/OPEN-ISSUES.md). |
| [`TEST-PLAN.md`](TEST-PLAN.md) | End-to-end testing strategy, stage breakdown, remediation items R-01 through R-46. |
| [`DASHBOARD-REQUIREMENTS.md`](DASHBOARD-REQUIREMENTS.md) | Authoritative Grafana spec: 3 dashboards, 16 panels (incl. leaderboard p20/p21). |
| [`COST-CALC-LUA.md`](COST-CALC-LUA.md) | Cost calculation module: pricing paths, `compute_cost`, model normalization. |
| [`PROPOSAL-LLM-GATEWAY-v3.md`](PROPOSAL-LLM-GATEWAY-v3.md) | Umbrella architecture: APISIX pivot rationale, plugin mapping, billing-grade contract, ClickHouse schema. Supersedes v2.0 (Kong, archived). |
| [`PLUGIN-FOUNDATION.md`](PLUGIN-FOUNDATION.md) | APISIX custom Lua plugin development foundation: file layout, manifest, schema, phase mapping, context/state, cosockets, custom Docker image, error discipline. |
| [`BUILTIN-PLUGINS.md`](BUILTIN-PLUGINS.md) | Configuration guide for APISIX built-in plugins: `openid-connect`, `ldap-auth`, `ai-proxy`, `ai-proxy-multi`, `limit-count`, `http-logger`, `prometheus`, `proxy-buffering`, `proxy-rewrite`. Zero custom code. |
| [`PLUGIN-REDACT-LUA.md`](PLUGIN-REDACT-LUA.md) | Custom Lua plugin (v1): PII redaction via `ngx.re` PCRE + file-based dictionary. PII Map in `ctx`. `body_filter` re-hydration with sliding window. Zero sidecars. |
| [`PLUGIN-REDACT-ENGINE.md`](PLUGIN-REDACT-ENGINE.md) | Optional NER sidecar (v2): Rust binary, ONNX BERT-tiny, `POST /ner`. Off-thread via `ngx.timer.at`. Best-effort enrichment. |
| [`PLUGIN-SEMANTIC-CACHE.md`](PLUGIN-SEMANTIC-CACHE.md) | Custom Lua plugin (v2): Redis VSS semantic cache via `lua-resty-redis` cosocket. Embedding via Rust sidecar (torch/llama.cpp). Canonical JSON storage + SSE synthesis on HIT. |
| [`DEPLOYMENT.md`](DEPLOYMENT.md) | Deployment infrastructure: docker-compose stack, `config.yaml`, `apisix.yaml`, custom Docker image, ClickHouse schema, Vector pipeline, reconciler job, health checks. |
| [`OPENCODE-INTEGRATION.md`](OPENCODE-INTEGRATION.md) | opencode integration: server API reference, provider/model selection, APISIX relay config, telemetry hooks, Grafana URLs, OpenAI compatibility assessment. |
| [`PROVIDER-XAI-GROK.md`](PROVIDER-XAI-GROK.md) | xAI Grok provider integration spec (draft): routes, auth, cost calc. |
| [`PROVIDER-MOONSHOT-KIMI.md`](PROVIDER-MOONSHOT-KIMI.md) | Moonshot Kimi provider integration spec (draft): OAuth device-code auth, routes, plugin spec, client usage. |

## Reading Order

1. `architecture/README.md`: how the gateway is built and start here; audit gaps in architecture/OPEN-ISSUES.md.
2. `PROPOSAL-LLM-GATEWAY-v3.md`: umbrella architecture and rationale.
3. `PLUGIN-FOUNDATION.md`: shared plugin development contracts.
4. `BUILTIN-PLUGINS.md`: built-in plugin configuration (auth, proxy, failover, telemetry).
5. `OPENCODE-INTEGRATION.md`: how opencode connects to the gateway.
6. `DASHBOARD-REQUIREMENTS.md`: Grafana panel spec and correctness criteria.
7. `PLUGIN-REDACT-LUA.md`: the v1 custom plugin (redaction).
8. `DEPLOYMENT.md`: how to deploy and operate.
9. v2 specs: `PLUGIN-SEMANTIC-CACHE.md`, `PLUGIN-REDACT-ENGINE.md`.

## License Posture

- **Apache APISIX 3.17.0**, Apache 2.0. ALL plugins OSS, no license enforcement,
  no tier split, no "free mode" cliff. Source code public. Docker images for every
  version.
- **Rust sidecars** (v2): `ort` (ONNX Runtime, MIT), `axum` (MIT), `tokenizers`
  (Apache 2.0). All dependencies MIT or Apache-2.0.
- No Kong, no Wasm, no Proxy-Wasm, no Enterprise licensing concerns.