# REQ-ENTERPRISE-AUTH: Enterprise Auth and AI Routing (Aspirational)

**Date:** 2026-07-17
**Status:** Draft
**Type:** Requirements
**Specification:** [SPEC-ENTERPRISE-AUTH](../specifications/SPEC-ENTERPRISE-AUTH.md)

> This document captures optional enterprise hardening features mined from the
> original design docs: OIDC bearer-only authentication (`openid-connect`),
> legacy AD authentication (`ldap-auth`, Kerberos via `forward-auth` in v2),
> canonical provider translation (`ai-proxy`), and multi-provider failover
> (`ai-proxy-multi`). These features are **not part of the deployed gateway**;
> the current deployment authenticates via `key-resolver` virtual keys,
> `kimi-auth`, and shared-key passthrough. They are recorded here as an
> opt-in target configuration for enterprise environments. Nothing in this
> document is implemented in the current codebase.

---

**Cross-references:**
- [SPEC-ENTERPRISE-AUTH](../specifications/SPEC-ENTERPRISE-AUTH.md): companion specification
- Legacy BUILTIN-PLUGINS §1-4 (absorbed)
- Legacy DEPLOYMENT §4.1 (absorbed)
- [`conf/apisix.yaml`](../../conf/apisix.yaml): actual deployed routes (none of these plugins present)
- [`conf/config.yaml`](../../conf/config.yaml): registered plugin list

---

## 1. Purpose & Scope

### 1.1 Purpose

Define the requirements an enterprise deployment of the gateway would satisfy
when fronting LLM traffic with corporate identity (OIDC / AD / Kerberos) and
multi-provider AI routing with failover, using only APISIX built-in plugins
(configuration-only, zero custom code).

### 1.2 Scope

**This document OWNS the requirements for:**
- Bearer-only OIDC authentication against an enterprise IdP (e.g. Keycloak realm `enterprise`)
- Claim-to-header mapping for tenant/user/tier context
- LDAP simple-bind authentication against legacy AD
- Kerberos/Negotiate validation (v2, via `forward-auth`)
- Single-provider `ai-proxy` translation and `stream_options.include_usage` enforcement
- Multi-provider `ai-proxy-multi` weighted failover with health checks

**This document DOES NOT:**
- Replace the deployed auth model (`key-resolver` + OpenBao virtual keys, `kimi-auth`)
- Mandate any of these features; each is independently opt-in
- Cover custom Lua glue beyond the small header-injection filters noted in the spec

### 1.3 Terminology

| Term | Definition |
|------|------------|
| IdP | Identity provider (e.g. Keycloak realm) |
| Bearer-only | Resource-server mode: validate JWT, no browser redirect |
| `X-Tenant-ID` / `X-Routing-Tier` | Unified context headers injected from token claims or AD attributes |
| Priority group | `ai-proxy-multi` target tier; lower priority number = primary |

## 2. Functional Requirements

### FR-1: OIDC Authentication (`openid-connect`)

| ID | Requirement |
|----|-------------|
| FR-1.1 | Enterprise API routes MAY be protected by the built-in `openid-connect` plugin in `bearer_only: true` mode against the enterprise IdP discovery URL. |
| FR-1.2 | When enabled, the plugin MUST validate JWT signature (JWKS cached in shared memory), expiry, audience, and scope. |
| FR-1.3 | The plugin SHOULD map claims to headers: `tenant_id` -> `X-Tenant-ID`, `sub` -> `X-User-ID`, `groups` -> `X-Routing-Tier`. |
| FR-1.4 | The access token MUST NOT be forwarded to the upstream (`access_token_in_authorization_header: false`). |
| FR-1.5 | Multi-issuer deployments MUST use one `openid-connect` instance per route, per issuer (separate routes or Host-based route matching). |
| FR-1.6 | All auth failures MUST fail closed: missing Bearer -> 401; expired/invalid token -> 401; cold-start JWKS unreachable -> 401; wrong audience/scope -> 403. |

### FR-2: LDAP Authentication (`ldap-auth`)

| ID | Requirement |
|----|-------------|
| FR-2.1 | Legacy AD environments MAY use the built-in `ldap-auth` plugin with LDAPS, a service-account bind DN, and `uid: sAMAccountName`. |
| FR-2.2 | LDAP bind credentials MUST come from the secret store, never inline plaintext. |
| FR-2.3 | Where `X-Tenant-ID` / `X-Routing-Tier` must derive from AD attributes, the deployment MUST use `forward-auth` to an external auth service (or a minimal Lua post-processor), since `ldap-auth` does not natively inject custom headers. |
| FR-2.4 | Kerberos/SPN (Negotiate) validation MAY be added in a v2 via `forward-auth` to an external Kerberos validation service; v1 covers LDAP simple bind only. |

### FR-3: Single-Provider AI Proxy (`ai-proxy`)

| ID | Requirement |
|----|-------------|
| FR-3.1 | Routes MAY use built-in `ai-proxy` to translate to a canonical OpenAI format for providers: OpenAI, Azure, Anthropic, Bedrock, Gemini, Vertex AI, and OpenAI-compatible endpoints (vLLM). |
| FR-3.2 | Provider API keys MUST be sourced from the secret store. |
| FR-3.3 | Every streaming route MUST enforce `stream_options.include_usage: true` (built-in injection if supported, else a small `access`-phase Lua filter). |

### FR-4: Multi-Provider Failover (`ai-proxy-multi`)

| ID | Requirement |
|----|-------------|
| FR-4.1 | Routes MAY use `ai-proxy-multi` with weighted targets and priority groups (lower priority = primary, higher = fallback). |
| FR-4.2 | `fallback_strategy` MUST be one of `rate_limiting`, `http_429`, `http_5xx`; the enterprise example uses `http_429`. |
| FR-4.3 | Non-streaming requests MUST retry across targets within `max_retries` before any bytes reach the client. |
| FR-4.4 | Streaming requests MUST only fail over before the first SSE event; once streaming begins the connection is committed. |
| FR-4.5 | Active health checks (`http_path: /v1/models`) SHOULD remove unhealthy targets from rotation automatically. |
| FR-4.6 | Streaming duration and response size SHOULD be capped (`max_stream_duration_ms`, `max_response_bytes`). |

## 3. Non-Functional Requirements

| ID | Requirement |
|----|-------------|
| NFR-1.1 | These features are configuration-only; they MUST NOT require new custom plugins (the small header/`stream_options` filters excepted). |
| NFR-1.2 | Secrets (OIDC client secret, LDAP bind password, provider API keys) MUST be vault/OpenBao references, never committed. |
| NFR-1.3 | Enabling any of these features MUST NOT change the behavior of the existing deployed routes (`relay-opencode*`, `relay-kimi*`, `relay-llamafile`, `gateway-provider-sync`). |
| NFR-1.4 | SSE streaming routes MUST disable proxy buffering (`proxy-buffering` plugin disabled). |

## 4. Constraints

| ID | Constraint | Source |
|----|------------|--------|
| C-1 | Fail closed on all auth errors (no `fail_open` default) | BUILTIN-PLUGINS.md §1.3 |
| C-2 | `ldap-auth` cannot inject custom headers natively | BUILTIN-PLUGINS.md §2.2 |
| C-3 | Streaming failover only pre-first-SSE-event | BUILTIN-PLUGINS.md §4.2 |
| C-4 | The enterprise route example is explicitly "future, not deployed" | DEPLOYMENT.md §4.1 |

## 5. Assumptions

| ID | Assumption |
|----|------------|
| A-1 | An enterprise IdP (Keycloak or equivalent) and/or AD domain controller is available in the target environment. |
| A-2 | APISIX version supports `ai-proxy` / `ai-proxy-multi` with the referenced fields. |
| A-3 | A secret store (OpenBao/vault) is reachable for credential references. |

## 6. Open Questions

| Q | Resolution |
|---|------------|
| Exact `stream_options` injection field in `ai-proxy` | Verify against APISIX docs at adoption time; Lua filter is the alternative |
| AD attribute -> header mapping | `forward-auth` external service or ~30-line Lua post-processor |

## 7. Verification Matrix

| # | Test | Maps to |
|---|------|---------|
| V1 | Expired/invalid JWT -> 401; missing Bearer -> 401 | FR-1.6 |
| V2 | Claims appear as `X-Tenant-ID`/`X-User-ID`/`X-Routing-Tier` headers | FR-1.3 |
| V3 | LDAP bind success/failure paths | FR-2.1 |
| V4 | Streaming route request body gains `stream_options.include_usage` | FR-3.3 |
| V5 | Primary target 429 -> fallback target serves (non-streaming) | FR-4.3 |
| V6 | Unhealthy target removed by active health check | FR-4.5 |

## 8. Implementation Status

| Item | Status | Evidence |
|------|--------|----------|
| FR-1.x `openid-connect` routes | Not implemented | no `openid-connect` in `conf/apisix.yaml` or `conf/config.yaml` plugin list |
| FR-2.x `ldap-auth` / Kerberos | Not implemented | no `ldap-auth` or `forward-auth` references in `conf/` |
| FR-3.x `ai-proxy` | Not implemented | no `ai-proxy` references in `conf/apisix.yaml` |
| FR-4.x `ai-proxy-multi` | Not implemented | no `ai-proxy-multi` references in `conf/apisix.yaml` |
| Claim/attribute header injection | Not implemented | no `claims_to_header` or forward-auth service in repo |
| Tests | Not implemented | no `tests/**` referencing openid/ldap/ai-proxy |
