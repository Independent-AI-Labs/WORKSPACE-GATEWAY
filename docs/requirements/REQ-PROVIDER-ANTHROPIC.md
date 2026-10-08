# REQ-PROVIDER-ANTHROPIC: Anthropic Providers (Gateway + Client-Authenticated Paths)

**Date:** 2026-09-28
**Status:** Draft
**Type:** Requirements
**Specification:** [SPEC-PROVIDER-ANTHROPIC](../specifications/SPEC-PROVIDER-ANTHROPIC.md)
**Research:** [RES-ANTHROPIC-OAUTH](../research/RES-ANTHROPIC-OAUTH.md)

> Serves Anthropic models behind two bare passthrough proxies: `/anthropic`
> and `/anthropic-coding-plan`. Every request, including the client's own
> Anthropic credentials (API key or subscription OAuth bearer) and beta
> headers, relays to api.anthropic.com verbatim. The gateway holds no
> Anthropic credential, runs no OAuth handshake, hosts no verification page,
> and stores no Anthropic token; the gateway service itself performs no
> subscription reuse.
>
> Three client-authenticated surfaces are supported:
> 1. `workspace-gw-anthropic-api-key`, an ordinary provider-sync catalog
>    entry (`auth.type: api_key`) for users with a regular Anthropic API key.
> 2. `workspace-gw-anthropic-coding-plan-passthrough`, a second provider-sync
>    catalog entry (`auth.type: passthrough`) that proxies the Anthropic
>    coding-plan (Claude Pro/Max subscription) endpoints on its own
>    `/anthropic-coding-plan` route. It carries no gateway credential and no
>    OAuth engine: the client's own subscription bearer, beta headers, and
>    `?beta=true` query relay byte-identical. Authentication remains entirely
>    client-side.
> 3. Claude Pro/Max subscription on the
>    `workspace-gw-anthropic-coding-plan-passthrough` provider, addable
>    directly through the OpenCode `/connect` TUI. Its provider-sync
>    `/opencode` block advertises a route-less `client_oauth` method, and the
>    login script registers a per-provider wrapper
>    (`res/opencode-plugin/workspace-gateway-anthropic-plan.ts`) that reuses
>    the maintained community plugin
>    (`@ex-machina/opencode-anthropic-auth`) but re-keys its OAuth hook to the
>    gateway provider id. The community plugin performs the Anthropic PKCE
>    exchange client-side, directly against Anthropic, and rewrites model
>    requests to look like Claude Code (research F4: OpenCode ships no
>    Anthropic auth since 1.3.0; a plugin is required). Routing uses the
>    provider block's `options.baseURL` (which carries the
>    `/anthropic-coding-plan/v1` path), not `ANTHROPIC_BASE_URL` (research
>    F6). The wrapper holds no Anthropic OAuth constant and makes no gateway
>    call.
> 4. An alternate client path remains the **built-in OpenCode `anthropic`
>    provider** with the community plugin and the
>    `res/scripts/opencode-anthropic-max.sh` installer. It is not the
>    repository's supported coding-plan path: the pinned community plugin
>    rewrites only the origin from `ANTHROPIC_BASE_URL`, so it cannot target a
>    path-prefixed gateway route (research F6).
>
> No committed file defines, overrides, or names the built-in `anthropic`
> provider's baseURL or models. Explicitly excluded: intercepting or hosting
> the client-side login on the gateway, and any modification of request
> bodies or auth headers on the passthrough route.

---

**Cross-references:**
- [SPEC-PROVIDER-ANTHROPIC](../specifications/SPEC-PROVIDER-ANTHROPIC.md): companion specification
- [RES-ANTHROPIC-OAUTH](../research/RES-ANTHROPIC-OAUTH.md): feasibility evidence
- [REQ-PROVIDER-SYNC](REQ-PROVIDER-SYNC.md): provider catalog and client-config service
- [`plugins/custom/provider-sync.lua`](../../plugins/custom/provider-sync.lua): OpenCode provider block rendering
- [`conf/providers/workspace-gw-anthropic-api-key.yaml`](../../conf/providers/workspace-gw-anthropic-api-key.yaml): API-key provider
- [`conf/providers/workspace-gw-anthropic-coding-plan-passthrough.yaml`](../../conf/providers/workspace-gw-anthropic-coding-plan-passthrough.yaml): coding-plan passthrough provider
- [`res/scripts/opencode-anthropic-max.sh`](../../res/scripts/opencode-anthropic-max.sh): community-plugin installer
- [`conf/apisix.yaml.j2`](../../conf/apisix.yaml.j2): relay route
- [`res/scripts/claude-gw.sh`](../../res/scripts/claude-gw.sh): client wrapper

---

## 1. Purpose & Scope

### 1.1 Purpose

Serve Anthropic models through WORKSPACE-GATEWAY with the client's own
Anthropic authentication passed through untouched. The gateway is a dumb
proxy; it never mints, stores, refreshes, or injects an Anthropic credential.
Client-side authentication surfaces are supported without any of them
requiring the gateway to handle Anthropic auth: a first-class API-key
provider, a first-class coding-plan (subscription) passthrough provider, and
the built-in OpenCode `anthropic` provider for Claude Pro/Max.

### 1.2 Scope

**This document OWNS the requirements for:**
- The `/anthropic/*` and `/anthropic-coding-plan/*` passthrough routes and
  their no-auth-plugin contract
- The `workspace-gw-anthropic-api-key` provider definition
- The `workspace-gw-anthropic-coding-plan-passthrough` provider definition
- The Claude Pro/Max path: the `client_oauth` provider-sync method, the
  repository-owned thin wrapper engine, the pinned community plugin
  dependency, the `res/scripts/opencode-anthropic-max.sh` installer, and the
  `ANTHROPIC_BASE_URL` runtime contract
- The `claude-gw.sh` wrapper contract

**This document DOES NOT:**
- Define provider-oauth plugin internals (owned by REQ-PROVIDER-KIMI /
  REQ-PROVIDER-OPENAI)
- Cover model catalog/pricing sync internals (owned by REQ-PROVIDER-SYNC)
- Cover the zai/openai/kimi/opencode providers
- Own the community plugin's implementation (it is an external dependency,
  pinned by this repo)

### 1.3 Terminology

| Term | Definition |
|------|------------|
| Passthrough | Client's own Anthropic credentials relayed verbatim; gateway holds no tokens |
| API-key provider | `workspace-gw-anthropic-api-key`: OpenCode stores the user's Anthropic API key and sends it as `x-api-key` |
| Coding-plan provider | `workspace-gw-anthropic-coding-plan-passthrough`: a `passthrough` catalog entry on its own `/anthropic-coding-plan` route; the client supplies its subscription bearer/API key client-side, gateway stores nothing |
| Subscription path | Client-side Claude Pro/Max on `workspace-gw-anthropic-coding-plan-passthrough`: route-less `client_oauth` method + per-provider thin wrapper over the community plugin, routed through the provider block's `options.baseURL` |
| Community plugin | The external, maintained OpenCode plugin (`@ex-machina/opencode-anthropic-auth`, pinned) that performs Claude Pro/Max PKCE OAuth client-side and injects the required Claude Code request shape |
| Thin wrapper | `res/opencode-plugin/workspace-gateway-anthropic-plan.ts`: repository-owned client-side engine that re-keys the community plugin's hook to a gateway provider id, redirects its refresh persistence, and adds `beta=true` for the prefixed messages path; holds no Anthropic OAuth constant |
| client_oauth | A route-less provider-sync auth method (`flow: client_oauth`) that instructs the login script to register the client-side wrapper engine; no gateway auth route, credential, or OAuth engine is involved |
| beta path | Subscription OAuth tokens require `anthropic-beta: oauth-2025-04-20` and the `?beta=true` messages path, authored client-side |

## 2. Functional Requirements

### FR-1: Route

| ID | Requirement |
|----|-------------|
| FR-1.1 | The gateway SHALL expose `relay-anthropic` (`/anthropic/*`) proxying to `api.anthropic.com:443` over HTTPS with path rewrite `^/anthropic/(.*)` to `/$1`. |
| FR-1.2 | Query strings (including `?beta=true`), request bodies, and response streams MUST pass through unmodified. |
| FR-1.3 | The gateway SHALL NOT expose any Anthropic login, callback, verification, or token endpoint. |
| FR-1.4 | The gateway SHALL expose `relay-anthropic-coding-plan` (`/anthropic-coding-plan/*`) proxying to the same `api.anthropic.com:443` upstream over HTTPS with path rewrite `^/anthropic-coding-plan/(.*)` to `/$1`, and with no auth-injecting or auth-stripping plugin. |

### FR-2: Transparent passthrough

| ID | Requirement |
|----|-------------|
| FR-2.1 | The `/anthropic/*` route MUST NOT run any auth-injecting or auth-stripping plugin: `Authorization`, `x-api-key`, `anthropic-beta`, `anthropic-version`, and `anthropic-organization` headers from the client MUST reach the upstream byte-identical. |
| FR-2.2 | The gateway MUST NOT custody, log, or rewrite any credential on this route beyond the standard redaction pipeline applied to all providers. |
| FR-2.3 | Client-visible behavior MUST equal talking to api.anthropic.com directly: same status codes, same error bodies, same streaming semantics. Documented client-side base-URL side effects (tool-search default, Remote Control disablement) are client behavior, not gateway defects. |
| FR-2.4 | Standard gateway observability MUST still apply: http-logger, redact, sse-usage, prometheus, request-id, limit-count, key-meta. |
| FR-2.5 | FR-2.1 through FR-2.4 MUST hold identically on `/anthropic-coding-plan/*`: no auth plugin, byte-identical credentials and `?beta=true` query, `accept-encoding: identity`, and the standard observability stack. The coding-plan route MUST be attributed to `workspace-gw-anthropic-coding-plan-passthrough` in `cost_calc.ROUTE_PROVIDERS` so subscription traffic is billed and reported separately from the API-key provider. |

### FR-3: Provider definition

| ID | Requirement |
|----|-------------|
| FR-3.1 | The repository SHALL provision exactly two Anthropic provider files, following the existing provider YAML schema and id contract, both using `npm: "@ai-sdk/anthropic"`: `workspace-gw-anthropic-api-key` (`provider.id: anthropic`, auth `api_key`) and `workspace-gw-anthropic-coding-plan-passthrough` (`provider.id: anthropic-coding-plan`, auth `passthrough`). |
| FR-3.2 | Each provider MUST use its own route: `/anthropic` for the API-key entry and `/anthropic-coding-plan` for the coding-plan passthrough. Both rewrite to `/$1` on the same `api.anthropic.com:443` upstream. No gateway login/callback/verification/token route and no gateway OAuth surface is introduced. |
| FR-3.3 | The built-in OpenCode provider id `anthropic` MUST NOT be defined or overridden by any committed provider file or static fragment. (The coding-plan provider is the supported subscription path; the built-in provider is never configured on disk.) |
| FR-3.4 | The repository MUST NOT ship a custom static-config fragment for Anthropic. The API-key and coding-plan providers are installed by `make setup-providers` (which registers the client-side auth method for the coding-plan provider); `make setup-anthropic-max` wires only the built-in-provider alternate path. |
| FR-3.5 | The coding-plan passthrough provider MUST declare `auth.type: passthrough` and MUST NOT carry a gateway credential, OAuth engine, or gateway auth route. Its auth methods, if any, are route-less and run entirely in the client. Authentication for it is 100% client-side. |
| FR-3.6 | Both providers SHALL source models and pricing from models.dev namespace `anthropic` (`model_source.provider`/`pricing.source.provider`); model ids MUST NOT be remapped. |

### FR-4: Claude Pro/Max subscription path (client-side)

| ID | Requirement |
|----|-------------|
| FR-4.1 | The subscription path MUST keep authentication client-side and MUST NOT require a gateway-issued credential; the gateway holds no Anthropic credential and runs no OAuth. |
| FR-4.2 | `workspace-gw-anthropic-coding-plan-passthrough` MUST be addable through the OpenCode `/connect` TUI: its provider-sync `/opencode` block MUST advertise a route-less `client_oauth` method, and the login script MUST register a per-provider wrapper importing `res/opencode-plugin/workspace-gateway-anthropic-plan.ts`. |
| FR-4.3 | The repository SHALL depend on the maintained community plugin `@ex-machina/opencode-anthropic-auth`, pinned to an exact version, which performs the Anthropic PKCE exchange client-side. |
| FR-4.4 | The thin wrapper MUST re-key the community plugin's `anthropic`-keyed OAuth hook to the gateway provider id, redirect its token-refresh persistence to that id, and add `?beta=true` for the gateway's prefixed `/v1/messages` path. It MUST NOT contain Anthropic OAuth constants and MUST NOT make any gateway call. |
| FR-4.5 | Routing for the coding-plan provider MUST use the provider block's `options.baseURL` (which carries the `/anthropic-coding-plan/v1` path). The community plugin's `ANTHROPIC_BASE_URL` rewrite copies only protocol/host and MUST NOT be relied on for a path-prefixed route (research F6). |
| FR-4.6 | The community plugin MUST perform the Anthropic PKCE exchange directly against Anthropic (client process); the gateway MUST NOT be involved in the authorization or token exchange. |
| FR-4.7 | The repository SHALL ship only this thin client-side wrapper as its own Anthropic auth code. This is an explicit exception to a "no repository-owned OAuth engine" constraint: the wrapper holds no OAuth constants and the gateway performs no auth. OAuth and Claude Code request rewriting remain the community plugin's responsibility. |
| FR-4.8 | `res/scripts/opencode-anthropic-max.sh` MUST add the pinned plugin spec idempotently (preserving unrelated plugin entries) and MUST NOT modify the `anthropic` provider block. Its `ANTHROPIC_BASE_URL` guidance applies only to the built-in-provider alternate path (research F6). |
| FR-4.9 | `res/scripts/claude-gw.sh` MUST allow selecting either Anthropic route (default `/anthropic-coding-plan`, the coding-plan passthrough; override `GW_ROUTE=/anthropic` for the API-key route) while still setting only `ANTHROPIC_BASE_URL`. |

### FR-5: Client wrapper (`res/scripts/claude-gw.sh`)

| ID | Requirement |
|----|-------------|
| FR-5.1 | The wrapper MUST set exactly one environment variable, `ANTHROPIC_BASE_URL` (default a reachable gateway origin), then exec `claude` with all arguments. |
| FR-5.2 | The wrapper MUST NOT set `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, or any other credential env: external credential envs disable the CLI's OAuth path (research F1). |
| FR-5.3 | The wrapper MUST fail with an install hint when `claude` is not on PATH. |

### FR-6: Provider models & pricing

| ID | Requirement |
|----|-------------|
| FR-6.1 | Model catalog and pricing for both the API-key and coding-plan passthrough providers SHALL sync from models.dev namespace `anthropic`; model ids MUST NOT be remapped. The built-in-provider subscription path uses the built-in provider's own models.dev catalog. |
| FR-6.2 | Provider display MUST use the `@ai-sdk/anthropic` npm package id for Anthropic-protocol clients. |

### FR-7: Security

| ID | Requirement |
|----|-------------|
| FR-7.1 | Anthropic credentials MUST never appear in gateway logs; the redact pipeline MUST cover OAuth token shapes. |
| FR-7.2 | The gateway MUST NOT persist any Anthropic OAuth token or pending authorization record; no Anthropic token/device prefix is provisioned in OpenBao. |
| FR-7.3 | Rate limits and key hashing MUST apply on both routes exactly as on existing provider routes. |
| FR-7.4 | Neither Anthropic route may attach a gateway credential: no token/device prefix in OpenBao, no auth route, no header injection. |

## 3. Non-Functional Requirements

| ID | Requirement |
|----|-------------|
| NFR-1 | Passthrough streaming MUST add no measurable first-byte latency beyond transport (proxy-buffering disabled, as all SSE routes). |
| NFR-2 | The route MUST remain under the standard route plugin budget and file size limits of the repo. |
| NFR-3 | The installer script MUST pass the repo's shell lint (`bash -n`) and have a self-check for its idempotent merge. |
| NFR-4 | The thin wrapper engine MUST pass the gateway Bun typecheck and MUST carry a `bun:test` unit test (upstream test style), preserving the repo's pinned plugin dependency and lockfile. |

## 4. Acceptance

| Scenario | Expected |
|----------|----------|
| `claude` with wrapper, `/login` done once | All model traffic flows through GW with CLI-owned credentials; GW logs show anthropic models; no gateway auth errors |
| `claude` streaming request via GW | Indistinguishable from direct api.anthropic.com streaming |
| OpenCode API-key provider installed with a key | `workspace-gw-anthropic-api-key/*` chats flow through GW; gateway stores nothing |
| Client POST to `/anthropic-coding-plan/v1/messages` with a client bearer | Relays byte-identical to `api.anthropic.com/v1/messages`; `usage_log` attributes the row to `workspace-gw-anthropic-coding-plan-passthrough`; gateway stores nothing |
| `claude-gw.sh` with `GW_ROUTE=/anthropic-coding-plan` | Same CLI-owned credentials; traffic flows through the coding-plan route, not `/anthropic` |
| `make setup-anthropic-max` then `/connect` → Anthropic → Claude Pro/Max (alternate built-in path) | Community plugin mints/refreshes the token against Anthropic; inference flows through GW; gateway stores nothing |
| `make setup-providers` then `/connect` → Anthropic Coding Plan → Claude Pro/Max | Thin wrapper offers the community PKCE flow under `workspace-gw-anthropic-coding-plan-passthrough`; token stays client-side; inference flows through `/anthropic-coding-plan`; gateway stores nothing |
| Coding-plan provider request in OpenCode | Routed via provider `options.baseURL` to `/anthropic-coding-plan/v1/messages?beta=true` carrying `anthropic-beta: oauth-2025-04-20` (research F6) |
| Wrapper token refresh past expiry | Refreshed token persisted under `workspace-gw-anthropic-coding-plan-passthrough`, not `anthropic` |
| Built-in `anthropic` provider in OpenCode | Untouched on disk; no committed file defines or overrides its baseURL |
| Gateway restart mid-session | Client refresh continues uninterrupted (client-side); no gateway state lost |
