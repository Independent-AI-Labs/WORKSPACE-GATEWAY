# ADR-001: Pivot from Kong Gateway to Apache APISIX

**Status:** Accepted (2026)
**Date:** 2026-07-17
**Type:** Architecture Decision Record

> Condensed from the legacy PROPOSAL-LLM-GATEWAY-v3 document §0/§1.
> The archived proposal is superseded by `docs/requirements/` +
> `docs/specifications/`; this ADR records only the decision and its rationale.

---

## Context

The v2.0 architecture proposal built the LLM gateway on Kong Gateway 3.14
(Enterprise image run unlicensed) with four custom Rust Proxy-Wasm plugins to
replace Enterprise-only capabilities. Deep research revealed structural
problems:

- Kong 3.14 Enterprise code is private; the public repo source stops at 3.9.3
  and 3.14 was never tagged on GitHub.
- Kong "free mode" was deprecated in 3.10 and removed in 3.15: the Admin API
  becomes read-only and DB-less operation breaks on restart.
- Key plugins (`openid-connect`, `ldap-auth-advanced`, `ai-proxy-advanced`,
  `ai-semantic-cache`) are Enterprise-only.
- Custom Rust Wasm filters require a `wasm32-wasip1` toolchain,
  `dispatch_http_call` async state machines, and `meta.json` Draft-4 schemas,
  with no socket access.
- The design needed 4 Rust sidecar binaries (redact-engine, ldap-bridge,
  cache-adapter, failover-translator) plus decK + Admin API + PostgreSQL for
  GitOps.

## Decision

Adopt **Apache APISIX 3.17.0** as the gateway platform, replacing Kong:

- Apache 2.0, fully public source with release tags for every version; no
  license enforcement, tier split, or "free mode" cliff.
- All required capabilities are OSS built-in plugins: `openid-connect`,
  `ldap-auth`, `ai-proxy`, `ai-proxy-multi`, `ai-rate-limiting`,
  `proxy-cache`, `http-logger`, `prometheus`, `proxy-buffering`.
- Custom logic written as pure Lua plugins on the OpenResty phase model:
  synchronous cosockets via `lua-resty-http` / `lua-resty-redis`.

### Plugin mapping (Kong Enterprise -> APISIX)

| Kong Enterprise plugin | APISIX replacement | Custom code? |
|------------------------|--------------------|--------------|
| `openid-connect` | `openid-connect` | No |
| `ldap-auth-advanced` | `ldap-auth` / `forward-auth` | No |
| `ai-proxy-advanced` | `ai-proxy-multi` | No |
| `ai-semantic-cache` | Custom Lua `semantic-cache` (v2) | Yes |
| Rate limiting | `ai-rate-limiting` | No |
| Telemetry | `http-logger` + `prometheus` | No |
| SSE buffering control | `proxy-buffering` | No |
| PII redaction (no Kong equivalent) | Custom Lua `redact` | Yes |

## Consequences

**Positive:**

- Custom plugin implementations reduced from 5 (2 Rust Wasm + 1 Lua + 2
  hybrid) to 2 custom Lua plugins (redaction, semantic-cache). Auth, failover,
  rate limiting, AI proxy, and telemetry become configuration-only.
- No Rust Wasm toolchain, no `dispatch_http_call` state machines, no
  `meta.json` schemas.
- Zero sidecars required for v1 (NER + embedding sidecars optional in v2).
- Config management via standalone YAML mode (file-driven hot reload) or ADC
  (`adc sync`) for GitOps; no decK/PostgreSQL dependency.

**Negative / trade-offs:**

- The v2.0 Kong design work (Rust Wasm plugin specs, sidecar contracts) is
  discarded; billing and reconciliation contracts transfer to the new platform.
- Team must own OpenResty/Lua plugin discipline (phase mapping, shared dicts,
  cosocket error handling) instead of Rust.

**Follow-on:**

- Current deployment runs APISIX in etcd/traditional mode (see
  [RUNBOOK-DEPLOYMENT](../runbooks/RUNBOOK-DEPLOYMENT.md) and
  [architecture](../architecture/README.md)); the standalone-YAML and
  enterprise OIDC designs in the archived proposal are aspirational and were
  not adopted.
