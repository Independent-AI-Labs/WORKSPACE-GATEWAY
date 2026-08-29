# SPEC-PROVIDER-ZAI: Z.ai Provider Implementation

**Date:** 2026-08-29
**Status:** Active
**Type:** Specification
**Requirements:** [REQ-PROVIDER-ZAI](../requirements/REQ-PROVIDER-ZAI.md)

> Implements the Z.ai provider as pure configuration: 2 own-key passthrough
> relay routes to `api.z.ai/api/coding/paas/v4` (GLM Coding Plan, OpenAI Chat
> Completions protocol) plus one OpenCode provider definition. No custom
> plugin code. Architecture context:
> [architecture/README.md](../architecture/README.md).

---

**Cross-references:**
- [REQ-PROVIDER-ZAI](../requirements/REQ-PROVIDER-ZAI.md): requirements
- [SPEC-PROVIDER-KIMI](SPEC-PROVIDER-KIMI.md): analog provider (adds OAuth/federated modes Z.ai does not have)
- [SPEC-GATEWAY-CORE](SPEC-GATEWAY-CORE.md): relay plugin stack baseline
- [`conf/apisix.yaml`](../../conf/apisix.yaml) / [`conf/apisix.yaml.j2`](../../conf/apisix.yaml.j2): routes
- [`conf/providers/workspace-gw-zai-api-key.yaml`](../../conf/providers/workspace-gw-zai-api-key.yaml): provider definition

---

## 1. Overview

```mermaid
graph TB
    C[Client] -->|Authorization: Bearer zai-key| ZK[/zai-key/* passthrough]
    ZK --> PRW[proxy-rewrite -> /api/coding/paas/v4/*]
    PRW --> API[api.z.ai GLM Coding Plan]
```

No new plugins, containers, or storage: Z.ai offers only static API keys
(no OAuth/device flow upstream), so own-key passthrough is the only (and
sufficient) mode. This mirrors Kimi's `/kimi-key/*` routes exactly.

## 2. Upstream Contract (verified 2026-08-29, docs.z.ai)

| Item | Value |
|------|-------|
| Host | `api.z.ai:443` (HTTPS) |
| Coding Plan base (this provider) | `/api/coding/paas/v4`: OpenAI Chat Completions, bills Coding Plan subscription quota |
| General base (NOT used) | `/api/paas/v4`: PAYG balance; coding subscription quota only works on the coding endpoint |
| Auth | `Authorization: Bearer <Z.ai API key>` (client-held, forwarded as-is) |
| Models | `glm-5.3`, `glm-5.3-flash`, `glm-5.2`, `glm-5.1`, `glm-5`, `glm-4.5-air`, ... |
| Out of scope endpoints | OpenAI Responses `/api/v1`, Anthropic Messages `/api/anthropic` |

Constraint (docs.z.ai): the coding and general endpoints are not
interchangeable; once a Coding Plan is purchased (even expired), balance-based
routing on alternative protocols requires manual allowlisting, so the coding
Chat Completions endpoint is the only reliable subscription path.

## 3. Routes

Both routes upstream to `api.z.ai:443` (HTTPS, `pass_host: node`) and rewrite
to `/api/coding/paas/v4/*`:

| Route id | URI | Rewrite | Auth |
|----------|-----|---------|------|
| `relay-zai-key` | `/zai-key/*` | `^/zai-key/(.*)` -> `/api/coding/paas/v4/$1` | none (passthrough) |
| `relay-zai-key-v1` | `/zai-key/v1/*` | `^/zai-key/v1/(.*)` -> `/api/coding/paas/v4/$1` | none (passthrough) |

Common route plugins: `proxy-rewrite`, `key-meta`, `limit-count` (100/60s per
`http_x_key_hash`), `prometheus`, `request-id`, `http-logger`,
`proxy-buffering` (disabled), `redact`, `sse-usage`.

Identical blocks are committed in `conf/apisix.yaml` and
`conf/apisix.yaml.j2` (Z.ai nodes are untemplated); the render drift test
(`tests/config/test_apisix_yaml_render.sh`) keeps them in sync.

## 4. OpenCode Provider

`conf/providers/workspace-gw-zai-api-key.yaml`: id
`workspace-gw-zai-api-key`, route `/zai-key`, npm
`@ai-sdk/openai-compatible`, auth `api_key`. Models from models.dev provider
`zai` (`strip_prefix: z-ai/`, `lowercase`), pricing from the same source with
`missing_policy: unknown`.

## 5. Error & Failure Model

The gateway adds no auth errors on these routes; upstream Z.ai responses
(401 invalid key, 429 quota) pass through verbatim. Gateway-side failures are
the common relay stack only (rate limit 429, telemetry sink errors).

## 6. Edge Cases & Decisions

- Coding endpoint chosen over general `/api/paas/v4`: subscription quota
  does not apply on the general endpoint (C-2 in REQ).
- `/zai-key/v1/*` variant mirrors the Kimi `-v1` pattern so OpenAI SDK
  `base_url=.../zai-key/v1` clients don't produce double-`v1` paths.
- GLM model-name aliasing (`z-ai/glm-*` dot/slash forms) is already handled
  by `model_registry.lua` and `vector.toml`; no Z.ai-specific aliases needed.

## 7. File Map

| File | Purpose | Key Changes |
|------|---------|-------------|
| `conf/apisix.yaml` | 2 `relay-zai-key*` routes | passthrough, coding rewrite |
| `conf/apisix.yaml.j2` | identical route blocks | drift-kept in sync |
| `conf/providers/workspace-gw-zai-api-key.yaml` | OpenCode provider definition | zai models.dev source |
| `tests/config/test_apisix_yaml.sh` | route assertions | 14-route count + Z.ai checks |

## 8. Implementation Status

| Component | Status | Evidence |
|-----------|--------|----------|
| 2 relay routes (.yaml + .j2) | Implemented | conf/apisix.yaml, conf/apisix.yaml.j2 |
| Provider YAML | Implemented | conf/providers/workspace-gw-zai-api-key.yaml |
| Config tests | Implemented | tests/config/test_apisix_yaml.sh |
