# REQ-PROVIDER-ANTHROPIC: Anthropic Providers (Transparent Passthrough + Device Facade)

**Date:** 2026-09-19
**Status:** Draft
**Type:** Requirements
**Specification:** [SPEC-PROVIDER-ANTHROPIC](../specifications/SPEC-PROVIDER-ANTHROPIC.md)
**Research:** [RES-ANTHROPIC-OAUTH](../research/RES-ANTHROPIC-OAUTH.md)

> Mandates two Anthropic providers behind the gateway. Provider A is a
> bare proxy: every request, including the client's own Anthropic
> credentials and beta headers, relays to api.anthropic.com verbatim;
> downstream clients keep their standard login and token mechanisms and
> users configure nothing beyond a base URL. Provider B is a custodial
> device-flow facade for clients with no Anthropic login capability
> (opencode, headless agents): the gateway owns the OAuth session,
> refreshes it, and presents a device-code login. Explicitly excluded:
> intercepting or hosting the client-side browser login for provider A
> (research F2: no supported path), and any modification of request
> bodies or auth headers on the passthrough route.

---

**Cross-references:**
- [SPEC-PROVIDER-ANTHROPIC](../specifications/SPEC-PROVIDER-ANTHROPIC.md): companion specification
- [RES-ANTHROPIC-OAUTH](../research/RES-ANTHROPIC-OAUTH.md): feasibility evidence
- [REQ-PROVIDER-KIMI](REQ-PROVIDER-KIMI.md): custodial OAuth provider pattern (device facade shape)
- [`plugins/custom/oauth-auth.lua`](../../plugins/custom/oauth-auth.lua): auth endpoints, session relay
- [`conf/apisix.yaml.j2`](../../conf/apisix.yaml.j2): relay routes
- [`res/scripts/claude-gw.sh`](../../res/scripts/claude-gw.sh): client wrapper

---

## 1. Purpose & Scope

### 1.1 Purpose

Serve Anthropic models through WORKSPACE-GATEWAY in two modes: with the
client's own Anthropic authentication passed through untouched
(transparency mode), and with gateway-custodial OAuth for clients that
cannot run a browser login (custody mode).

### 1.2 Scope

**This document OWNS the requirements for:**
- The `/anthropic/*` passthrough route and its no-auth-plugin contract
- The `/anthropic-device/*` custodial route, its device facade
  endpoints, token custody, and upstream injection
- The two provider definitions exposed to clients
- The `claude-gw.sh` wrapper contract

**This document DOES NOT:**
- Define oauth-auth plugin internals (owned by SPEC-PROVIDER-ANTHROPIC
  implementation notes and the existing oauth engine family)
- Cover model catalog/pricing sync internals (owned by REQ-PROVIDER-SYNC)
- Cover the zai/openai/kimi providers

### 1.3 Terminology

| Term | Definition |
|------|------------|
| Passthrough mode | Client's own Anthropic credentials relayed verbatim; gateway holds no tokens |
| Custody mode | Gateway holds OAuth tokens in OpenBao; client holds a gateway session bearer |
| Device facade | Gateway-implemented RFC 8628-style login over Anthropic's browser PKCE grant (upstream has no device flow) |
| beta path | OAuth tokens require `anthropic-beta: oauth-2025-04-20` and `/v1/messages?beta=true` |

## 2. Functional Requirements

### FR-1: Routes

| ID | Requirement |
|----|-------------|
| FR-1.1 | The gateway SHALL expose `relay-anthropic` (`/anthropic/*`) proxying to `api.anthropic.com:443` over HTTPS with path rewrite `^/anthropic/(.*)` to `/$1`. |
| FR-1.2 | The gateway SHALL expose `relay-anthropic-device` (`/anthropic-device/*`) proxying to the same upstream with the same rewrite, plus the `oauth-auth` plugin with an `anthropic` protocol engine. |
| FR-1.3 | Query strings (including `?beta=true`), request bodies, and response streams MUST pass through both routes unmodified. |

### FR-2: Provider A, transparent passthrough (`workspace-gw-anthropic`)

| ID | Requirement |
|----|-------------|
| FR-2.1 | The `/anthropic/*` route MUST NOT run any auth-injecting or auth-stripping plugin: `Authorization`, `x-api-key`, `anthropic-beta`, `anthropic-version`, and `anthropic-organization` headers from the client MUST reach the upstream byte-identical. |
| FR-2.2 | The gateway MUST NOT custody, log, or rewrite any credential on this route beyond the standard redaction pipeline applied to all providers. |
| FR-2.3 | Client-visible behavior MUST equal talking to api.anthropic.com directly: same status codes, same error bodies, same streaming semantics. Documented client-side base-URL side effects (tool-search default, Remote Control disablement) are client behavior, not gateway defects. |
| FR-2.4 | Standard gateway observability MUST still apply: http-logger, redact, sse-usage, prometheus, request-id, limit-count, key-meta. |

### FR-3: Provider B, custodial device facade (`workspace-gw-anthropic-device`)

| ID | Requirement |
|----|-------------|
| FR-3.1 | The gateway SHALL implement the login endpoints `POST /anthropic-device/auth/device`, `POST /anthropic-device/auth/device/poll`, and a browser-completable verification page under `/anthropic-device/auth/verify`, per the device facade pattern of the kimi provider. |
| FR-3.2 | The upstream authorization MUST be Anthropic's browser PKCE grant with the verified constants and quirks (client id, PKCE S256 with state equal to the verifier, `code=true`, JSON token bodies, `CODE#STATE` splitting); the gateway MUST NOT invent parameters outside them. |
| FR-3.3 | Tokens MUST be stored in OpenBao under `secret/data/gateway/anthropic-tokens/` (sessions) and `secret/data/gateway/anthropic-device/` (pending device records), keyed per the existing oauth-store conventions. |
| FR-3.4 | On relay, the gateway MUST inject the live access token as `Authorization: Bearer`, MUST ensure the OAuth beta header (`anthropic-beta: oauth-2025-04-20`) and `?beta=true` are present on `/v1/messages`, and MUST strip the client's gateway credential from the upstream request. |
| FR-3.5 | The gateway MUST refresh custodial tokens before expiry (refresh threshold per existing oauth session logic) and MUST tolerate refresh responses that omit a new refresh token (keep the previous one). |
| FR-3.6 | Anthropic API keys (`sk-ant-`) presented on the custodial route MUST be rejected with a pointer to `/anthropic` (passthrough provider), mirroring the kimi reject_key contract. |
| FR-3.7 | Upstream OAuth constants (hosts, paths, client id) MUST live in one route-level config block; no scattering across plugin code. |

### FR-4: Client wrapper (`res/scripts/claude-gw.sh`)

| ID | Requirement |
|----|-------------|
| FR-4.1 | The wrapper MUST set exactly one environment variable, `ANTHROPIC_BASE_URL` (default `https://gw.workspaceguardrails.com/anthropic`), then exec `claude` with all arguments. |
| FR-4.2 | The wrapper MUST NOT set `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, or any other credential env: external credential envs disable the CLI's OAuth path (research F1). |
| FR-4.3 | The wrapper MUST fail with an install hint when `claude` is not on PATH. |

### FR-5: Provider definitions & models

| ID | Requirement |
|----|-------------|
| FR-5.1 | Two provider files SHALL be provisioned: `workspace-gw-anthropic` (route `/anthropic`, auth type passthrough) and `workspace-gw-anthropic-device` (route `/anthropic-device`, auth type oauth, method device facade), following the existing provider yaml schema. |
| FR-5.2 | Model catalog and pricing SHALL sync from models.dev provider `anthropic`; model ids MUST NOT be remapped. |
| FR-5.3 | Provider display MUST use the `@anthropic-ai/sdk` npm package id for Anthropic-protocol clients. |

### FR-6: Security

| ID | Requirement |
|----|-------------|
| FR-6.1 | Custodial tokens and device records MUST never appear in logs; the redact pipeline MUST cover OAuth token shapes. |
| FR-6.2 | The verification page MUST be reachable over HTTPS on the public gateway origin only, and device codes MUST expire (15 minutes default). |
| FR-6.3 | Rate limits and key hashing MUST apply on both routes exactly as on existing provider routes. |

## 3. Non-Functional Requirements

| ID | Requirement |
|----|-------------|
| NFR-1 | Passthrough streaming MUST add no measurable first-byte latency beyond transport (proxy-buffering disabled, as all SSE routes). |
| NFR-2 | The custodial engine MUST keep upstream constants overridable per environment (staging/prod) without code changes. |
| NFR-3 | Both routes MUST remain under the standard route plugin budget and file size limits of the repo. |

## 4. Acceptance

| Scenario | Expected |
|----------|----------|
| `claude` with wrapper, `/login` done once | All model traffic flows through GW with CLI-owned credentials; GW logs show anthropic models; no gateway auth errors |
| `claude` streaming request via GW | Indistinguishable from direct api.anthropic.com streaming |
| opencode + provider B after device login | Requests succeed; client never sees an Anthropic credential |
| Device login abandoned | Poll returns pending then expires; no token stored |
| `sk-ant-` key on `/anthropic-device` | Rejected with pointer to `/anthropic` |
