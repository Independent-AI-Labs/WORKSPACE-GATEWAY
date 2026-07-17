# SPEC-ENTERPRISE-AUTH: Enterprise Auth and AI Routing Implementation

**Date:** 2026-07-17
**Status:** Draft
**Type:** Specification
**Requirements:** [REQ-ENTERPRISE-AUTH](../requirements/REQ-ENTERPRISE-AUTH.md)

> Intended APISIX plugin configurations for optional enterprise hardening:
> `openid-connect` (bearer-only OIDC), `ldap-auth` (legacy AD, Kerberos in v2
> via `forward-auth`), `ai-proxy` (single-provider canonical translation),
> and `ai-proxy-multi` (weighted multi-provider failover). These are
> configuration-only designs using built-in plugins; they are not part of the
> deployed gateway (`conf/apisix.yaml`) and are marked "future, not deployed"
> in the source docs. Nothing here exists in the codebase yet.

---

**Cross-references:**
- [REQ-ENTERPRISE-AUTH](../requirements/REQ-ENTERPRISE-AUTH.md): requirements contract
- Legacy BUILTIN-PLUGINS §1-4 (absorbed)
- Legacy DEPLOYMENT §4.1 enterprise example (absorbed)
- [`conf/apisix.yaml`](../../conf/apisix.yaml): deployed routes (no enterprise plugins)
- [`conf/config.yaml`](../../conf/config.yaml): registered plugin list

---

## 1. Overview

The enterprise profile adds a corporate identity layer and multi-provider AI
routing on top of the gateway using only APISIX built-in plugins. It replaces
what earlier architectures did with Kong Enterprise plugins and custom Rust
Proxy-Wasm filters. The deployed gateway's routes and auth model
(`key-resolver`, `kimi-auth`, shared-key passthrough) are unchanged; this
profile defines additional routes for enterprise environments.

## 2. Architectural Principles

### 2.1 Configuration-only

Zero custom plugins; all capabilities come from built-in plugin
configuration (plus at most ~30-line Lua filters for header injection and
`stream_options` enforcement).

### 2.2 Fail closed

All auth failures deny the request. No `fail_open` default; degraded mode
requires explicit route-level opt-in.

### 2.3 Secrets by reference

All credentials are vault/OpenBao references (`{{vault:secret/...}}`), never
inline.

### 2.4 Streaming-aware routing

SSE routes disable proxy buffering; failover only happens before the first
SSE event.

## 3. System Diagram

```
Client (enterprise)
  | Authorization: Bearer <IdP JWT>        or LDAP basic auth
  v
APISIX route: /v1/chat/completions (enterprise profile)
  |-- openid-connect (bearer_only) --> Keycloak realm "enterprise"
  |      claims_to_header: tenant_id->X-Tenant-ID, sub->X-User-ID, groups->X-Routing-Tier
  |-- proxy-buffering: disabled (SSE)
  |-- redact (custom Lua, existing)
  |-- ai-proxy-multi
  |      targets: openai gpt-4o (w70,p1) / azure prod-deployment (w30,p1)
  |                / gpt-4o-mini (w100,p2 fallback)
  |      fallback_strategy: http_429, active health checks /v1/models
  |-- limit-count
  v
Upstream LLM providers
```

## 4. `openid-connect` Configuration

```yaml
plugins:
  openid-connect:
    client_id: "llm-gateway"
    client_secret: "{{vault:secret/oidc/client_secret}}"
    discovery: "https://ami-keycloak:8082/realms/enterprise/.well-known/openid-configuration"
    scope: "openid profile email"
    bearer_only: true
    realm: "enterprise"
    claims_to_header:
      - claim: "tenant_id"
        header: "X-Tenant-ID"
      - claim: "sub"
        header: "X-User-ID"
      - claim: "groups"
        header: "X-Routing-Tier"
    access_token_in_authorization_header: false
```

| Property | Value |
|----------|-------|
| Mode | bearer-only resource server |
| Backing library | `lua-resty-openidc` (JWKS cache in shared memory) |
| Multi-issuer | one plugin instance per route per issuer; Host-based route matching for per-tenant IdPs |

Failure modes (all fail closed):

| Failure | Behavior |
|---------|----------|
| No `Authorization: Bearer` | 401 `WWW-Authenticate: Bearer realm="enterprise"` |
| Expired / invalid token | 401 `error="invalid_token"` |
| JWKS unreachable (cold start) | 401 `error="key_material_unavailable"` |
| Wrong audience / scope | 403 `error="insufficient_scope"` |

## 5. `ldap-auth` Configuration

```yaml
plugins:
  ldap-auth:
    ldap_uri: "ldaps://dc01.ad.corp:636"
    base_dn: "DC=corp,DC=example,DC=com"
    bind_dn: "CN=svc-gateway,OU=ServiceAccounts,DC=corp,DC=example,DC=com"
    bind_password: "{{vault:secret/ldap/service_password}}"
    use_tls: true
    timeout: 5000
    uid: "sAMAccountName"
```

Header injection: `ldap-auth` does not natively map LDAP attributes to
headers. For `X-Tenant-ID` / `X-Routing-Tier` from AD attributes, use
`forward-auth` delegating to an external auth service (LDAP bind + attribute
extraction + header injection), or a minimal ~30-line `access`-phase Lua
post-processor reading the `ldap-auth` consumer context.

Kerberos (v2): Negotiate/SPN validation via `forward-auth` to an external
Kerberos validation service. v1 covers LDAP simple bind only.

## 6. `ai-proxy` Configuration (Single Provider)

```yaml
plugins:
  ai-proxy:
    provider: "openai"
    model: "gpt-4o"
    api_key: "{{vault:secret/ai/openai_key}}"
    override_endpoint: "https://api.openai.com/v1/chat/completions"
    pass_through_body: true
```

Provider-specific notes:

| Provider | Endpoint | Auth header |
|----------|----------|-------------|
| OpenAI | `api.openai.com/v1/chat/completions` | `Authorization: Bearer <key>` |
| Azure | `<instance>.openai.azure.com/openai/deployments/<id>/chat/completions?api-version=...` | `api-key: <key>` (deployment id in config) |
| Anthropic | `api.anthropic.com/v1/messages` | `x-api-key: <key>` (Messages API body shape) |
| Bedrock | `bedrock-runtime.<region>.amazonaws.com/model/<id>/invoke[-with-response-stream]` | SigV4 (handled internally) |
| vLLM | `<host>:<port>/v1/chat/completions` | `Authorization: Bearer <key>` |

`stream_options.include_usage` enforcement (billing-grade contract): use
built-in injection if the plugin supports it; otherwise a ~20-line
`access`-phase Lua filter parses the body, checks `stream == true`, and injects
`stream_options.include_usage = true` if absent.

## 7. `ai-proxy-multi` Configuration (Failover)

```yaml
plugins:
  ai-proxy-multi:
    provider: openai
    targets:
      - provider: openai
        model: gpt-4o
        api_key: "{{vault:secret/ai/openai_key}}"
        weight: 70
        priority: 1
      - provider: azure
        model: prod-deployment
        api_key: "{{vault:secret/ai/azure_key}}"
        override_endpoint: "https://azure-us-east.openai.azure.com/openai/deployments/prod-deployment/chat/completions?api-version=2024-06-01"
        weight: 30
        priority: 1
      - provider: openai
        model: gpt-4o-mini
        api_key: "{{vault:secret/ai/openai_key}}"
        weight: 100
        priority: 2
    fallback_strategy: "http_429"
    max_retries: 3
    retry_on_failure_within_ms: 10000
    max_stream_duration_ms: 120000
    max_response_bytes: 10485760
    health_check:
      active:
        type: http
        http_path: "/v1/models"
        healthy_interval: 30
        unhealthy_interval: 5
```

Failover semantics:

| Case | Behavior |
|------|----------|
| Non-streaming | full retry across targets within `max_retries`, before any client bytes |
| Streaming | failover only before first SSE event; then connection committed |
| `fallback_strategy` | `rate_limiting` (429 only), `http_429` (429 + rate-limit headers), `http_5xx` |
| Health checks | active HTTP probes; unhealthy targets removed from rotation |

## 8. Enterprise Route Example (from DEPLOYMENT.md §4.1)

```yaml
# aspirational (NOT conf/apisix.yaml)
routes:
  - id: llm-chat-completions
    uri: /v1/chat/completions
    methods: [POST]
    plugins:
      openid-connect:
        client_id: "llm-gateway"
        client_secret: "{{vault:secret/oidc/client_secret}}"
        discovery: "http://ami-keycloak:8082/realms/enterprise/.well-known/openid-configuration"
        scope: "openid profile email"
        bearer_only: true
        realm: "enterprise"
        claims_to_header:
          - { claim: "tenant_id", header: "X-Tenant-ID" }
          - { claim: "sub", header: "X-User-ID" }
          - { claim: "groups", header: "X-Routing-Tier" }
      proxy-buffering:
        disabled: true
      redact:
        patterns_file: "/etc/apisix/redact-patterns.json"
        stream_mode: buffer
        on_error: closed
      ai-proxy-multi:
        provider: openai
        targets:
          - { provider: openai, model: gpt-4o, api_key: "{{vault:secret/ai/openai_key}}", weight: 70, priority: 1 }
          - { provider: azure, model: prod-deployment, api_key: "{{vault:secret/ai/azure_key}}", weight: 30, priority: 1 }
        fallback_strategy: "http_429"
        max_retries: 3
        retry_on_failure_within_ms: 10000
        max_stream_duration_ms: 120000
      limit-count:
        count: 100
        time_window: 60
        rejected_code: 429
        key_type: var
```

## 9. Edge Cases & Decisions

- **Cold-start JWKS failure:** 401 (fail closed), not a silent passthrough.
- **AD attribute mapping:** delegated to `forward-auth` or a Lua filter; never
  inline in `ldap-auth`.
- **Committed SSE streams:** mid-stream provider failure cannot fail over;
  the client must handle termination and reconnect.
- **Config examples target standalone `apisix.yaml` or ADC/Admin API**;
  adoption into this repo's etcd-backed `role: traditional` deployment would
  apply them via the Admin API/ADC.

## 10. File Map

| File | Purpose | Key Changes |
|------|---------|-------------|
| `conf/apisix.yaml` / Admin API (planned) | enterprise routes with the plugin blocks above | add routes when adopted |
| external forward-auth service (planned, optional) | LDAP attribute / Kerberos header injection | new service, only if AD headers needed |
| Lua filters (planned, optional) | `stream_options` enforcement, AD group -> header | ~20-30 lines each |

## 11. Implementation Status

| Component | Status | Evidence |
|-----------|--------|----------|
| `openid-connect` route config | Not implemented | grep `openid-connect` in `conf/`: no match |
| `ldap-auth` config | Not implemented | grep `ldap-auth` in `conf/`: no match |
| Kerberos `forward-auth` service | Not implemented | no `forward-auth` references or Kerberos service in repo |
| `ai-proxy` config | Not implemented | grep `ai-proxy` in `conf/apisix.yaml`: no match |
| `ai-proxy-multi` config | Not implemented | grep `ai-proxy-multi` in `conf/`: no match |
| Claims-to-header injection | Not implemented | no `claims_to_header` in `conf/` |
| `stream_options` filter | Not implemented | no `stream_options` references in `plugins/custom/` |
| Tests | Not implemented | no `tests/**` referencing openid/ldap/ai-proxy/kerberos |
