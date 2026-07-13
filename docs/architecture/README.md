# WORKSPACE-GATEWAY Architecture

Deep technical reference for components, plugins, data flows, and schema.
For quick start, ports, and distributed diagrams see
[`README.md`](../../README.md). For deploy commands see
[`DEPLOYMENT.md`](../DEPLOYMENT.md). For test stages see
[`TEST-PLAN.md`](../TEST-PLAN.md).

**Audit gaps:** [`OPEN-ISSUES.md`](OPEN-ISSUES.md)

## Reading order

| # | Document | Scope |
|---|----------|-------|
| 1 | [`OVERVIEW.md`](OVERVIEW.md) | etcd mode, 3 routes, provider-agnostic framing |
| 2 | [`RUNTIME-TOPOLOGY.md`](RUNTIME-TOPOLOGY.md) | Compose services, networks, volumes |
| 3 | [`LLAMAFILE-UPSTREAM.md`](LLAMAFILE-UPSTREAM.md) | VM-hosted local LLM for zero-cost e2e |
| 4 | [`PLUGIN-PIPELINE.md`](PLUGIN-PIPELINE.md) | Phase priorities, per-route plugin matrix |
| 5 | [`CUSTOM-PLUGINS.md`](CUSTOM-PLUGINS.md) | key-resolver, key-meta, redact, sse-usage, cost_calc |
| 6 | [`BUILTIN-PLUGINS.md`](BUILTIN-PLUGINS.md) | request-id, limit-count, http-logger, prometheus, proxy-* |
| 7 | [`REQUEST-LIFECYCLE.md`](REQUEST-LIFECYCLE.md) | Federated request sequence diagram |
| 8 | [`KEY-MANAGEMENT.md`](KEY-MANAGEMENT.md) | OpenBao KV, scripts, entrypoint |
| 9 | [`TELEMETRY-AND-SCHEMA.md`](TELEMETRY-AND-SCHEMA.md) | Vector, ClickHouse tables, migrations |

## Visual flows (README)

Request, telemetry, metrics, and control-plane diagrams live in the
owning [`README.md`](../../README.md) sections (Architecture, Plugins,
Configuration, Key Management), not duplicated here.

## Related docs

| Document | When to read |
|----------|--------------|
| [`DASHBOARD-REQUIREMENTS.md`](../DASHBOARD-REQUIREMENTS.md) | Grafana panel specs (16 panels) |
| [`COST-CALC-LUA.md`](../COST-CALC-LUA.md) | Cost calculation and model normalization |
| [`PLUGIN-REDACT-LUA.md`](../PLUGIN-REDACT-LUA.md) | Redact plugin deep spec |
| [`OPENCODE-INTEGRATION.md`](../OPENCODE-INTEGRATION.md) | opencode provider wiring |
| [`workflows/WORKFLOW-CREATING-DIAGRAMS.md`](../../workflows/WORKFLOW-CREATING-DIAGRAMS.md) | Diagram authoring rules |

**Last updated:** 2026-07-13