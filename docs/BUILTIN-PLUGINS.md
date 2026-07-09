# APISIX Built-in Plugin Configuration Guide

**Document ID:** AMI-PROP-LLMGW-BUILTIN-PLUGINS-v1.0
**Status:** Draft
**Date:** 2026-07-05
**Parent:** `PROPOSAL-LLM-GATEWAY-v3.md`

This document specifies the configuration for all APISIX built-in plugins used by
the LLM Gateway. These replace the custom Rust Proxy-Wasm filters and Kong
Enterprise plugins from the v2.0 architecture. **Zero custom code**, all
capabilities are configuration-only.

Config examples below go in `apisix.yaml` (standalone YAML mode) or are applied
via ADC/Admin API (traditional mode). See `DEPLOYMENT.md` for the full
`apisix.yaml` file.

---

## 1. Auth: `openid-connect` (OIDC / OAuth2)

Replaces: Kong Enterprise `openid-connect` plugin and custom Rust Wasm filter.

Uses `lua-resty-openidc` under the hood: JWKS caching in shared memory, JWT
signature verification, token introspection, discovery endpoint support.

### 1.1 Config for bearer-only API routes (Keycloak)

```yaml
plugins:
  openid-connect:
    client_id: "llm-gateway"
    client_secret: "{{vault:secret/oidc/client_secret}}"
    discovery: "https://ami-keycloak:8082/realms/enterprise/.well-known/openid-configuration"
    scope: "openid profile email"
    bearer_only: true
    realm: "enterprise"
    set Claims_to_header:              # inject unified context headers
      - claim: "tenant_id"
        header: "X-Tenant-ID"
      - claim: "sub"
        header: "X-User-ID"
      - claim: "groups"
        header: "X-Routing-Tier"
    access_token_in_authorization_header: false  # don't pass token to upstream
```

### 1.2 Multi-issuer

One `openid-connect` plugin instance per route, per issuer. For multi-tenant
with different IdPs, use separate routes or a route-matching condition on `Host`
header with different plugin configs.

### 1.3 Failure modes

| Failure | Behavior |
|---------|----------|
| No `Authorization: Bearer` header | 401 `WWW-Authenticate: Bearer realm="enterprise"` |
| Expired / invalid token | 401 `error="invalid_token"` |
| JWKS unreachable (cold start) | 401 `error="key_material_unavailable"` (fail-closed) |
| Wrong audience / scope | 403 `error="insufficient_scope"` |

All failures fail closed (no `fail_open` option, use route-level config to
opt into degraded mode if ever needed, per AGENTS.md Rule 13).

---

## 2. Auth: `ldap-auth` (Legacy AD)

Replaces: Kong Enterprise `ldap-auth-advanced` and custom Rust Wasm + bridge.

### 2.1 Config

```yaml
plugins:
  ldap-auth:
    ldap_uri: "ldaps://dc01.ad.corp:636"
    base_dn: "DC=corp,DC=example,DC=com"
    bind_dn: "CN=svc-gateway,OU=ServiceAccounts,DC=corp,DC=example,DC=com"
    bind_password: "{{vault:secret/ldap/service_password}}"
    use_tls: true
    timeout: 5000
    uid: "sAMAccountName"              # attribute to match against username
```

### 2.2 Header injection

`ldap-auth` does not natively inject custom headers from LDAP attributes.
For `X-Tenant-ID` / `X-Routing-Tier` from AD attributes, use `forward-auth`
plugin delegating to an external auth service that performs LDAP bind +
attribute extraction + header injection. Alternatively, a tiny Lua plugin
(30 lines) in `access` phase can post-process the `ldap-auth` consumer
context to inject headers from AD group membership.

### 2.3 Kerberos (v2)

For Kerberos SPN validation (Negotiate auth), use `forward-auth` plugin
delegating to an external Kerberos validation service. This is a v2
enhancement; v1 covers LDAP simple bind only.

---

## 3. AI Proxy: `ai-proxy` (Single Provider)

Replaces: Kong OSS `ai-proxy` plugin.

Provides canonical OpenAI format translation for upstream providers.
Supports OpenAI, Azure, Anthropic, Bedrock, Gemini, Vertex AI, and
OpenAI-compatible endpoints (vLLM).

### 3.1 Config

```yaml
plugins:
  ai-proxy:
    provider: "openai"
    model: "gpt-4o"
    api_key: "{{vault:secret/ai/openai_key}}"
    override_endpoint: "https://api.openai.com/v1/chat/completions"
    # stream_options.include_usage enforcement:
    # ai-proxy supports stream_options in the request body; verify per provider
    pass_through_body: true             # pass client body fields through
```

### 3.2 `stream_options.include_usage` enforcement

The billing-grade contract (PROPOSAL §6.2) requires `stream_options.include_usage:
true` on every streaming route. Two approaches:

- **Built-in:** Configure `ai-proxy` to inject `stream_options.include_usage` if
  the plugin supports it (verify field name in APISIX 3.17.0 docs).
- **Lua glue:** A 20-line custom Lua plugin in `access` phase that parses the
  request body, checks `stream == true`, and injects
  `stream_options.include_usage = true` if absent.

### 3.3 Provider-specific notes

| Provider | Endpoint | Auth header | Notes |
|----------|----------|-------------|-------|
| OpenAI | `api.openai.com/v1/chat/completions` | `Authorization: Bearer <key>` | Full `stream_options` support |
| Azure | `<instance>.openai.azure.com/openai/deployments/<id>/chat/completions?api-version=...` | `api-key: <key>` | `model` field ignored; deployment-id is config |
| Anthropic | `api.anthropic.com/v1/messages` | `x-api-key: <key>` | Body shape differs (Messages API) |
| Bedrock | `bedrock-runtime.<region>.amazonaws.com/model/<id>/invoke[-with-response-stream]` | SigV4 signed headers | `ai-proxy` handles SigV4 internally |
| vLLM | `<host>:<port>/v1/chat/completions` | `Authorization: Bearer <key>` | OpenAI-compatible |

---

## 4. AI Proxy: `ai-proxy-multi` (Multi-Provider Failover)

Replaces: Kong Enterprise `ai-proxy-advanced` and custom Lua + Rust hybrid.

Provides weighted load balancing, priority groups, fallback strategies,
retry, and active health checks across multiple LLM providers.

### 4.1 Config

```yaml
plugins:
  ai-proxy-multi:
    provider: openai                  # canonical output format (OpenAI shape)
    targets:
      - provider: openai
        model: gpt-4o
        api_key: "{{vault:secret/ai/openai_key}}"
        weight: 70
        priority: 1                   # lower = primary; higher = fallback
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
        priority: 2                   # fallback tier (only used when tier 1 fails)
    fallback_strategy: "http_429"     # trigger fallback on 429 (also: rate_limiting, http_5xx)
    max_retries: 3
    retry_on_failure_within_ms: 10000 # retry window for non-streaming
    max_stream_duration_ms: 120000    # cap streaming duration
    max_response_bytes: 10485760      # 10MB response cap
    health_check:
      active:
        type: http
        http_path: "/v1/models"       # OpenAI liveness endpoint
        healthy_interval: 30
        unhealthy_interval: 5
```

### 4.2 Failover semantics

- **Non-streaming:** Full retry across targets within `max_retries`. If primary
  returns 429/5xx, next target (by priority + weight) is tried before any bytes
  reach the client.
- **Streaming:** Failover only before the first SSE event. Once streaming begins,
  the connection is committed; client must handle SSE termination + reconnect.
- **`fallback_strategy`:** `rate_limiting` (fallback on 429 only), `http_429`
  (429 + rate limit headers), `http_5xx` (any 5xx).
- **Health checks:** Active HTTP probes to `http_path`; unhealthy targets
  removed from rotation automatically.

### 4.3 `stream_options` enforcement

Same as `ai-proxy` §3.2. Configure at the `ai-proxy-multi` level if supported,
or use the Lua glue plugin.

---

## 5. Rate Limiting: `limit-count` (Request RPM)

### 5.1 Overview

Uses APISIX built-in `limit-count` plugin (fixed window algorithm) enforced
on both routes. Scoped by `X-Key-Hash` header (set by `key-meta` plugin) so
each unique client key gets its own independent counter. `ai-rate-limiting`
is NOT used: it requires `ai-proxy`/`ai-proxy-multi` to populate token
usage context, which our route chain does not include.

### 5.2 Passthrough route (`/opencode/*`)

Same static limit for all passthrough keys (no OpenBao resolution):

```yaml
limit-count:
  count: 100
  time_window: 60
  rejected_code: 429
  key_type: var
  key: http_x_key_hash
  policy: local
```

### 5.3 Federated route (`/opencode_federated/*`)

Per-key variable limits read from OpenBao by `key-resolver` and injected as
headers `X-Gateway-Rate-Limit-RPM` / `X-Gateway-Rate-Limit-Window`:

```yaml
limit-count:
  rules:
    - count: "$http_x_gateway_rate_limit_rpm"
      time_window: "$http_x_gateway_rate_limit_window"
      key: "$http_x_key_hash"
  rejected_code: 429
  policy: local
```

### 5.4 Per-key token/cost budget (Tier 3: custom Lua, not a built-in plugin)

In addition to RPM, `key-resolver` reads `token_budget`, `cost_budget`,
`budget_window`, and `budget_type` from the key's OpenBao record. At access
phase it checks a `ngx.shared.quota_counters` dict against the budget;
if spent >= budget the request is rejected with 429. The `sse-usage` plugin
increments the counter at log phase with the tokens or cost (in cents)
consumed in the response.

Budget fields are stored per-key in OpenBao:
- `token_budget`: token limit per window (0 = unlimited)
- `cost_budget`: cost limit in cents per window (0 = unlimited)
- `budget_window`: time window in seconds (default 86400)
- `budget_type`: `"tokens"` or `"cost"` (default `"tokens"`)

---

## 6. Telemetry: `http-logger` + `prometheus`

### 6.1 `http-logger` (billing audit log)

Sends the full request/response log payload to Vector for ClickHouse ingest.

```yaml
plugins:
  http-logger:
    uri: "http://vector:8080/ingest"
    method: POST
    content_type: "application/json"
    batch_max_size: 1                  # send immediately (billing needs real-time)
    include_req_body: true             # capture request body for audit
    include_resp_body: false           # response body too large for SSE
    concat_method: "json"
```

The log payload includes `ai.proxy.usage.*` fields (token counts, model,
provider, latency) assembled by `ai-proxy` in the log phase. Custom Lua
plugins add their fields via `core.log.set_metadata(...)` or by setting
`ctx` fields that `http-logger` serializes.

### 6.2 `prometheus` (real-time metrics)

```yaml
plugins:
  prometheus:
    prefer_name: true                  # use route/service names in metrics
    export_uri: "/apisix/prometheus/metrics"
    # Metrics exposed: request count, latency, status code by route/consumer
    # ai-proxy adds: ai_llm_tokens_total, ai_llm_request_duration
```

Scrape from Prometheus (`ami-prometheus:9091`) at `/apisix/prometheus/metrics`.

---

## 7. SSE: `proxy-buffering`

Disables NGINX's proxy buffering per-route. Required for SSE streaming:
without it, nginx buffers the entire SSE stream before sending to the client.

```yaml
plugins:
  proxy-buffering:
    disabled: true
```

Apply only to streaming routes. Non-streaming routes can leave buffering
enabled (default) for better throughput.

**Merged in APISIX 3.17.0** (PR #13446). Verify the plugin is enabled in
`config.yaml` `plugins:` list.

---

## 8. Header Hygiene: `proxy-rewrite`

Strips context headers (`X-Tenant-ID`, `X-User-ID`, `X-Routing-Tier`) before
egress to upstream LLM providers. Prevents identity leakage to third-party APIs.

```yaml
plugins:
  proxy-rewrite:
    headers:
      remove:
        - "X-Tenant-ID"
        - "X-User-ID"
        - "X-Routing-Tier"
        - "X-Token-Scopes"
        - "X-Token-Issuer"
        - "X-Redact-Active"
        - "X-Redact-Error"
```

Runs in `rewrite` phase (before `access`), so headers are stripped before
any upstream connection. Alternatively, a tiny Lua plugin in `access` phase
can do this if `proxy-rewrite` ordering is insufficient.

---

## 9. Plugin Ordering on Routes

APISIX runs plugins in `priority` order (higher first). The full chain for
the LLM chat route:

```
openid-connect (2599) → ldap-auth (2599) → semantic-cache (2550, v2)
→ redact (2500, v1) → ai-proxy-multi (2402) → ai-proxy (2402)
→ limit-count (2002) → proxy-buffering (2800, nginx directive)
→ proxy-rewrite (2996) → http-logger (410) → prometheus (500)
```

Note: `proxy-rewrite` and `proxy-buffering` have high priorities because they
set nginx directives, not standard access-phase logic. They execute early
in the request lifecycle regardless of other plugin priorities.

### 9.1 Example route definition (standalone YAML)

```yaml
routes:
  - id: llm-chat-completions
    uri: /v1/chat/completions
    methods: [POST]
    plugins:
      openid-connect:
        # ... (§1.1 config)
      proxy-buffering:
        disabled: true
      redact:
        patterns_file: "/etc/apisix/redact-patterns.yaml"
        stream_mode: buffer
        on_error: closed
      ai-proxy-multi:
        # ... (§4.1 config)
      limit-count:
        # ... (§5 config)
      proxy-rewrite:
        headers:
          remove: ["X-Tenant-ID", "X-User-ID", "X-Routing-Tier"]
      http-logger:
        # ... (§6.1 config)
      prometheus:
        prefer_name: true
```

For v2, add `semantic-cache` plugin between auth and redact.

---

## 10. Verification Checklist

Before production deployment, verify:

- [ ] `openid-connect` correctly validates JWTs against Keycloak discovery endpoint
- [ ] `claims_to_header` mapping injects `X-Tenant-ID` / `X-User-ID` / `X-Routing-Tier`
- [ ] `ldap-auth` binds successfully against AD DC with TLS
- [ ] `ai-proxy-multi` fails over on 429 (inject 429 from mock provider)
- [ ] `ai-proxy` `stream_options.include_usage` is enforced (or Lua glue plugin works)
- [ ] `limit-count` blocks requests when RPM exceeded (returns 429)
- [ ] `proxy-buffering` disabled → SSE chunks arrive at client incrementally (not buffered)
- [ ] `proxy-rewrite` strips all context headers from upstream request
- [ ] `http-logger` sends log payloads to Vector → ClickHouse
- [ ] `prometheus` metrics endpoint is scraped by `ami-prometheus:9091`

---

**End of document.**
