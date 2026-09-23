# WORKSPACE-GATEWAY Documentation

**Project:** WORKSPACE-GATEWAY  -  High-Performance Enterprise Multi-Tenant LLM Gateway
**Platform:** Apache APISIX 3.18.0 (traditional/etcd mode)
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
| [`requirements/REQ-ENTERPRISE-AUTH.md`](requirements/REQ-ENTERPRISE-AUTH.md) | Enterprise auth (OIDC/LDAP) requirements (Retired 2026-09-23) |
| [`requirements/REQ-KEYCLOAK-INTEGRATION.md`](requirements/REQ-KEYCLOAK-INTEGRATION.md) | Inbound identity: native `openid-connect`/`authz-keycloak` against the Keycloak `workspace` domain (Draft) |
| [`requirements/REQ-GATEWAY-GOVERNANCE.md`](requirements/REQ-GATEWAY-GOVERNANCE.md) | Control surface: delegated administration and control-action audit (Draft) |
| [`requirements/REQ-AI-PROXY.md`](requirements/REQ-AI-PROXY.md) | Native AI protocol normalization decision and duplication record (Draft, Not Adopted) |
| [`requirements/REQ-PROVIDER-KIMI.md`](requirements/REQ-PROVIDER-KIMI.md) | Moonshot Kimi provider integration |
| [`requirements/REQ-PROVIDER-OPENAI.md`](requirements/REQ-PROVIDER-OPENAI.md) | OpenAI browser/headless OAuth provider integration |
| [`requirements/REQ-PROVIDER-SYNC.md`](requirements/REQ-PROVIDER-SYNC.md) | Provider catalog/pricing sync service |
| [`requirements/REQ-PROVIDER-ZAI.md`](requirements/REQ-PROVIDER-ZAI.md) | Z.ai GLM provider integration (own-key passthrough) |
| [`requirements/REQ-PROVIDER-ANTHROPIC.md`](requirements/REQ-PROVIDER-ANTHROPIC.md) | Anthropic provider integration |
| [`requirements/REQ-PROVIDER-ALIBABA-TOKEN-PLAN.md`](requirements/REQ-PROVIDER-ALIBABA-TOKEN-PLAN.md) | Alibaba Cloud Token Plan provider integration (own-key passthrough, Implemented) |
| [`requirements/REQ-PROVIDER-XAI.md`](requirements/REQ-PROVIDER-XAI.md) | xAI Grok provider integration (Draft) |
| [`requirements/REQ-REDACT.md`](requirements/REQ-REDACT.md) | PII redaction plugin (v1) |
| [`requirements/REQ-REDACT-ENGINE.md`](requirements/REQ-REDACT-ENGINE.md) | NER redaction engine (Draft, v2) |
| [`requirements/REQ-SEMANTIC-CACHE.md`](requirements/REQ-SEMANTIC-CACHE.md) | Semantic cache (Draft, v2) |
| [`requirements/REQ-USEFULNESS-TELEMETRY.md`](requirements/REQ-USEFULNESS-TELEMETRY.md) | Practical-usefulness metrics: TTFT, cancel/rejection signals, cruncher, dashboard (Implemented) |
| [`requirements/REQ-STATS-MIGRATION.md`](requirements/REQ-STATS-MIGRATION.md) | opencode SQLite → ClickHouse stats migrator (Implemented) |
| [`requirements/REQ-SECURITY-HARDENING.md`](requirements/REQ-SECURITY-HARDENING.md) | 2026-09 exposure hardening: ClickHouse authN/Z, body isolation, tiered retention, Grafana lockdown, network segmentation, etcd RBAC, edge contract |

### specifications/  -  implementation specs (SPEC-*)

| Document | Scope |
|----------|-------|
| [`specifications/SPEC-GATEWAY-CORE.md`](specifications/SPEC-GATEWAY-CORE.md) | Core gateway implementation: routes, config, deployment |
| [`specifications/SPEC-BILLING-TELEMETRY.md`](specifications/SPEC-BILLING-TELEMETRY.md) | sse-usage, Vector pipeline, ClickHouse schema |
| [`specifications/SPEC-COST-CALC.md`](specifications/SPEC-COST-CALC.md) | cost_calc + provider_sync_pricing implementation |
| [`specifications/SPEC-DASHBOARD.md`](specifications/SPEC-DASHBOARD.md) | Grafana dashboards implementation |
| [`specifications/SPEC-ENTERPRISE-AUTH.md`](specifications/SPEC-ENTERPRISE-AUTH.md) | Enterprise auth implementation (Retired 2026-09-23) |
| [`specifications/SPEC-KEYCLOAK-INTEGRATION.md`](specifications/SPEC-KEYCLOAK-INTEGRATION.md) | Inbound OIDC/authz implementation against Keycloak (Draft) |
| [`specifications/SPEC-GATEWAY-GOVERNANCE.md`](specifications/SPEC-GATEWAY-GOVERNANCE.md) | Governance/control-surface implementation (Draft) |
| [`specifications/SPEC-AI-PROXY.md`](specifications/SPEC-AI-PROXY.md) | Native `ai-proxy` audit and not-adopted decision (Draft) |
| [`specifications/SPEC-PLUGIN-FOUNDATION.md`](specifications/SPEC-PLUGIN-FOUNDATION.md) | Custom Lua plugin development foundation |
| [`specifications/SPEC-PROVIDER-KIMI.md`](specifications/SPEC-PROVIDER-KIMI.md) | provider-oauth plugin and Kimi routes |
| [`specifications/SPEC-PROVIDER-OPENAI.md`](specifications/SPEC-PROVIDER-OPENAI.md) | provider-oauth plugin and ChatGPT relay |
| [`specifications/SPEC-PROVIDER-SYNC.md`](specifications/SPEC-PROVIDER-SYNC.md) | provider-sync plugin implementation |
| [`specifications/SPEC-PROVIDER-ZAI.md`](specifications/SPEC-PROVIDER-ZAI.md) | Z.ai GLM passthrough routes |
| [`specifications/SPEC-PROVIDER-ANTHROPIC.md`](specifications/SPEC-PROVIDER-ANTHROPIC.md) | Anthropic passthrough routes |
| [`specifications/SPEC-PROVIDER-ALIBABA-TOKEN-PLAN.md`](specifications/SPEC-PROVIDER-ALIBABA-TOKEN-PLAN.md) | Alibaba Cloud Token Plan passthrough routes (Implemented) |
| [`specifications/SPEC-PROVIDER-XAI.md`](specifications/SPEC-PROVIDER-XAI.md) | xAI provider implementation (Draft) |
| [`specifications/SPEC-REDACT.md`](specifications/SPEC-REDACT.md) | redact plugin implementation |
| [`specifications/SPEC-REDACT-ENGINE.md`](specifications/SPEC-REDACT-ENGINE.md) | NER engine implementation (Draft) |
| [`specifications/SPEC-SEMANTIC-CACHE.md`](specifications/SPEC-SEMANTIC-CACHE.md) | Semantic cache implementation (Draft) |
| [`specifications/SPEC-USEFULNESS-TELEMETRY.md`](specifications/SPEC-USEFULNESS-TELEMETRY.md) | Usefulness telemetry implementation: TTFT capture, batch cruncher, dashboard (Implemented) |
| [`specifications/SPEC-STATS-MIGRATION.md`](specifications/SPEC-STATS-MIGRATION.md) | opencode stats migrator implementation (Implemented) |
| [`specifications/SPEC-SECURITY-HARDENING.md`](specifications/SPEC-SECURITY-HARDENING.md) | Hardening implementation: provision script, migrations 000010/000011, network/port surface, writer auth, runbooks |
| [`specifications/SPEC-SQL-STRUCTURE.md`](specifications/SPEC-SQL-STRUCTURE.md) | Externalized `conf/sql/` tree: templating, loaders, sqlfluff lint, no-inline-SQL guard |

### research/  -  upstream findings

| Document | Scope |
|----------|-------|
| [`research/RES-ANTHROPIC-OAUTH.md`](research/RES-ANTHROPIC-OAUTH.md) | Anthropic OAuth findings |
| [`research/RES-PROVIDER-ALIBABA-TOKEN-PLAN.md`](research/RES-PROVIDER-ALIBABA-TOKEN-PLAN.md) | Alibaba Cloud Token Plan endpoint catalog and verification |

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
[`AUTH-MODEL.md`](architecture/AUTH-MODEL.md),
[`TELEMETRY-AND-SCHEMA.md`](architecture/TELEMETRY-AND-SCHEMA.md),
[`OPEN-ISSUES.md`](architecture/OPEN-ISSUES.md).

### runbooks/  -  operations

| Document | Scope |
|----------|-------|
| [`runbooks/RUNBOOK-DEPLOYMENT.md`](runbooks/RUNBOOK-DEPLOYMENT.md) | Deploy and operate the stack |
| [`runbooks/RUNBOOK-KEYS.md`](runbooks/RUNBOOK-KEYS.md) | Issue, list, revoke virtual keys; manage upstream key pools |
| [`runbooks/RUNBOOK-CLIENT-LOGIN.md`](runbooks/RUNBOOK-CLIENT-LOGIN.md) | Client login flows (opencode provider login) |
| [`runbooks/RUNBOOK-EDGE-PROXY.md`](runbooks/RUNBOOK-EDGE-PROXY.md) | Edge trust contract for the public Grafana endpoint |
| [`runbooks/RUNBOOK-SECRETS.md`](runbooks/RUNBOOK-SECRETS.md) | Credential inventory, rotation, ClickHouse backups |

### TODO.md  -  tracked implementation work

[`TODO.md`](TODO.md) records the detailed, ordered work required to finish the
gateway-owned Bun plugin packaging, OAuth verification, and documentation
consistency checks.

The plugin itself uses Bun and the published `@opencode-ai/plugin` package.
Its runtime/bootstrap and CI integration must follow the established
`WORKSPACE-CI` and `WORKSPACE-VM` conventions rather than modifying the
OpenCode source checkout or relying on a global developer installation.

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

- **Apache APISIX 3.18.0**, Apache 2.0. All plugins OSS, no license
  enforcement, no tier split. Docker images for every version.
- No Kong, no Wasm, no Proxy-Wasm, no Enterprise licensing concerns.
