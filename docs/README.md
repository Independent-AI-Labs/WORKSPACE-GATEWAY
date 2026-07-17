# WORKSPACE-GATEWAY Documentation

**Project:** WORKSPACE-GATEWAY  -  High-Performance Enterprise Multi-Tenant LLM Gateway
**Platform:** Apache APISIX 3.17.0 (traditional/etcd mode)
**Date:** 2026-07-17

Purpose: this is the hub for all project documentation. Documents are
organized by type: requirement contracts (REQ-*), implementation
specifications (SPEC-*), architecture deep-dives, operational runbooks,
test plans, API references, and historical proposals (ADRs).

Documents with **Status: Draft** describe features that are **not yet
implemented**; their Implementation Status sections mark every component
as not implemented.

## Tree

### requirements/  -  requirement contracts (REQ-*)

| Document | Scope |
|----------|-------|
| [`requirements/REQ-GATEWAY-CORE.md`](requirements/REQ-GATEWAY-CORE.md) | Core gateway: routes, etcd control plane, built-in plugins |
| [`requirements/REQ-BILLING-TELEMETRY.md`](requirements/REQ-BILLING-TELEMETRY.md) | Billing-grade telemetry: usage_log, ClickHouse schema |
| [`requirements/REQ-COST-CALC.md`](requirements/REQ-COST-CALC.md) | Cost calculation and pricing ownership |
| [`requirements/REQ-DASHBOARD.md`](requirements/REQ-DASHBOARD.md) | Grafana dashboards and panels |
| [`requirements/REQ-ENTERPRISE-AUTH.md`](requirements/REQ-ENTERPRISE-AUTH.md) | Enterprise auth (OIDC/LDAP) requirements |
| [`requirements/REQ-PROVIDER-KIMI.md`](requirements/REQ-PROVIDER-KIMI.md) | Moonshot Kimi provider integration |
| [`requirements/REQ-PROVIDER-SYNC.md`](requirements/REQ-PROVIDER-SYNC.md) | Provider catalog/pricing sync service |
| [`requirements/REQ-PROVIDER-XAI.md`](requirements/REQ-PROVIDER-XAI.md) | xAI Grok provider integration (Draft) |
| [`requirements/REQ-REDACT.md`](requirements/REQ-REDACT.md) | PII redaction plugin (v1) |
| [`requirements/REQ-REDACT-ENGINE.md`](requirements/REQ-REDACT-ENGINE.md) | NER redaction engine (Draft, v2) |
| [`requirements/REQ-SEMANTIC-CACHE.md`](requirements/REQ-SEMANTIC-CACHE.md) | Semantic cache (Draft, v2) |

### specifications/  -  implementation specs (SPEC-*)

| Document | Scope |
|----------|-------|
| [`specifications/SPEC-GATEWAY-CORE.md`](specifications/SPEC-GATEWAY-CORE.md) | Core gateway implementation: routes, config, deployment |
| [`specifications/SPEC-BILLING-TELEMETRY.md`](specifications/SPEC-BILLING-TELEMETRY.md) | sse-usage, Vector pipeline, ClickHouse schema |
| [`specifications/SPEC-COST-CALC.md`](specifications/SPEC-COST-CALC.md) | cost_calc + provider_sync_pricing implementation |
| [`specifications/SPEC-DASHBOARD.md`](specifications/SPEC-DASHBOARD.md) | Grafana dashboards implementation |
| [`specifications/SPEC-ENTERPRISE-AUTH.md`](specifications/SPEC-ENTERPRISE-AUTH.md) | Enterprise auth implementation |
| [`specifications/SPEC-PLUGIN-FOUNDATION.md`](specifications/SPEC-PLUGIN-FOUNDATION.md) | Custom Lua plugin development foundation |
| [`specifications/SPEC-PROVIDER-KIMI.md`](specifications/SPEC-PROVIDER-KIMI.md) | kimi-auth plugin and Kimi routes |
| [`specifications/SPEC-PROVIDER-SYNC.md`](specifications/SPEC-PROVIDER-SYNC.md) | provider-sync plugin implementation |
| [`specifications/SPEC-PROVIDER-XAI.md`](specifications/SPEC-PROVIDER-XAI.md) | xAI provider implementation (Draft) |
| [`specifications/SPEC-REDACT.md`](specifications/SPEC-REDACT.md) | redact plugin implementation |
| [`specifications/SPEC-REDACT-ENGINE.md`](specifications/SPEC-REDACT-ENGINE.md) | NER engine implementation (Draft) |
| [`specifications/SPEC-SEMANTIC-CACHE.md`](specifications/SPEC-SEMANTIC-CACHE.md) | Semantic cache implementation (Draft) |

### architecture/  -  deep technical reference

Hub: [`architecture/README.md`](architecture/README.md)  -  reading order for
[`OVERVIEW.md`](architecture/OVERVIEW.md),
[`RUNTIME-TOPOLOGY.md`](architecture/RUNTIME-TOPOLOGY.md),
[`LLAMAFILE-UPSTREAM.md`](architecture/LLAMAFILE-UPSTREAM.md),
[`PLUGIN-PIPELINE.md`](architecture/PLUGIN-PIPELINE.md),
[`CUSTOM-PLUGINS.md`](architecture/CUSTOM-PLUGINS.md),
[`BUILTIN-PLUGINS.md`](architecture/BUILTIN-PLUGINS.md),
[`REQUEST-LIFECYCLE.md`](architecture/REQUEST-LIFECYCLE.md),
[`KEY-MANAGEMENT.md`](architecture/KEY-MANAGEMENT.md),
[`TELEMETRY-AND-SCHEMA.md`](architecture/TELEMETRY-AND-SCHEMA.md),
[`OPEN-ISSUES.md`](architecture/OPEN-ISSUES.md).

### runbooks/  -  operations

| Document | Scope |
|----------|-------|
| [`runbooks/RUNBOOK-DEPLOYMENT.md`](runbooks/RUNBOOK-DEPLOYMENT.md) | Deploy and operate the stack |
| [`runbooks/RUNBOOK-KEYS.md`](runbooks/RUNBOOK-KEYS.md) | Issue, list, revoke virtual keys |
| [`runbooks/RUNBOOK-CLIENT-LOGIN.md`](runbooks/RUNBOOK-CLIENT-LOGIN.md) | Client login flows (opencode provider login) |

### testplans/

| Document | Scope |
|----------|-------|
| [`testplans/TEST-PLAN.md`](testplans/TEST-PLAN.md) | End-to-end testing strategy and stage breakdown |

### reference/

| Document | Scope |
|----------|-------|
| [`reference/OPENCODE-SERVER-API.md`](reference/OPENCODE-SERVER-API.md) | opencode server HTTP API reference |

### proposals/  -  historical decisions

| Document | Scope |
|----------|-------|
| [`proposals/ADR-001-APISIX-PIVOT.md`](proposals/ADR-001-APISIX-PIVOT.md) | ADR: pivot to Apache APISIX (rationale, not current truth) |

## Reading order for newcomers

1. [`architecture/OVERVIEW.md`](architecture/OVERVIEW.md)  -  what the gateway is, routes, plugins.
2. [`requirements/REQ-GATEWAY-CORE.md`](requirements/REQ-GATEWAY-CORE.md) + [`specifications/SPEC-GATEWAY-CORE.md`](specifications/SPEC-GATEWAY-CORE.md)  -  core contract and implementation.
3. [`architecture/PLUGIN-PIPELINE.md`](architecture/PLUGIN-PIPELINE.md) + [`architecture/CUSTOM-PLUGINS.md`](architecture/CUSTOM-PLUGINS.md)  -  request-path plugins.
4. [`architecture/TELEMETRY-AND-SCHEMA.md`](architecture/TELEMETRY-AND-SCHEMA.md) + [`specifications/SPEC-BILLING-TELEMETRY.md`](specifications/SPEC-BILLING-TELEMETRY.md)  -  usage accounting.
5. [`runbooks/RUNBOOK-DEPLOYMENT.md`](runbooks/RUNBOOK-DEPLOYMENT.md)  -  run it.
6. [`testplans/TEST-PLAN.md`](testplans/TEST-PLAN.md)  -  verify it.
7. Draft docs (`REQ-SEMANTIC-CACHE`, `REQ-REDACT-ENGINE`, `REQ-PROVIDER-XAI` and their SPECs)  -  planned v2 features.

## License Posture

- **Apache APISIX 3.17.0**, Apache 2.0. All plugins OSS, no license
  enforcement, no tier split. Docker images for every version.
- No Kong, no Wasm, no Proxy-Wasm, no Enterprise licensing concerns.
