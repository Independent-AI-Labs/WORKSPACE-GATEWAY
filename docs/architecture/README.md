# WORKSPACE-GATEWAY Architecture

**Date:** 2026-07-17

Deep technical reference for components, plugins, data flows, and schema.
For the doc hub see [`docs/README.md`](../README.md).

**Audit gaps:** [`OPEN-ISSUES.md`](OPEN-ISSUES.md)

## Reading order

| # | Document | Scope |
|---|----------|-------|
| 1 | [`OVERVIEW.md`](OVERVIEW.md) | etcd mode, 10 routes, provider-agnostic framing |
| 2 | [`RUNTIME-TOPOLOGY.md`](RUNTIME-TOPOLOGY.md) | Compose services, networks, volumes |
| 3 | [`LLAMAFILE-UPSTREAM.md`](LLAMAFILE-UPSTREAM.md) | VM-hosted local LLM for zero-cost e2e |
| 4 | [`PLUGIN-PIPELINE.md`](PLUGIN-PIPELINE.md) | Phase priorities, per-route plugin matrix |
| 5 | [`CUSTOM-PLUGINS.md`](CUSTOM-PLUGINS.md) | key-resolver, key-meta, kimi-auth, provider-sync, sse-usage, redact + libs |
| 6 | [`BUILTIN-PLUGINS.md`](BUILTIN-PLUGINS.md) | request-id, limit-count, http-logger, prometheus, proxy-* |
| 7 | [`REQUEST-LIFECYCLE.md`](REQUEST-LIFECYCLE.md) | Federated request sequence diagram |
| 8 | [`KEY-MANAGEMENT.md`](KEY-MANAGEMENT.md) | OpenBao KV, scripts, entrypoint |
| 9 | [`TELEMETRY-AND-SCHEMA.md`](TELEMETRY-AND-SCHEMA.md) | Vector, ClickHouse tables, migrations |

## Related docs

| Document | When to read |
|----------|--------------|
| [`../requirements/`](../requirements/) | REQ-* requirement contracts (each links its SPEC) |
| [`../specifications/`](../specifications/) | SPEC-* implementation specifications |
| [`../runbooks/`](../runbooks/) | Operational runbooks: deployment, keys, client login |
| [`../testplans/TEST-PLAN.md`](../testplans/TEST-PLAN.md) | End-to-end testing strategy and stage breakdown |
| [`../reference/OPENCODE-SERVER-API.md`](../reference/OPENCODE-SERVER-API.md) | opencode server HTTP API reference |
| [`../proposals/ADR-001-APISIX-PIVOT.md`](../proposals/ADR-001-APISIX-PIVOT.md) | Historical rationale: pivot to APISIX |
