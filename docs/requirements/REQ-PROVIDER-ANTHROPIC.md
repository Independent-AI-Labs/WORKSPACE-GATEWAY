# REQ-PROVIDER-ANTHROPIC: Anthropic Providers (Gateway + Client-Authenticated Paths)

**Date:** 2026-09-28
**Status:** Draft
**Type:** Requirements
**Specification:** [SPEC-PROVIDER-ANTHROPIC](../specifications/SPEC-PROVIDER-ANTHROPIC.md)
**Research:** [RES-ANTHROPIC-OAUTH](../research/RES-ANTHROPIC-OAUTH.md)

> Serves Anthropic models behind the gateway's one bare `/anthropic` proxy.
> Every request, including the client's own Anthropic credentials (API key or
> subscription OAuth bearer) and beta headers, relays to api.anthropic.com
> verbatim. The gateway holds no Anthropic credential, runs no OAuth
> handshake, hosts no verification page, and stores no Anthropic token; the
> gateway service itself performs no subscription reuse.
>
> Two client-authenticated paths are supported:
> 1. `workspace-gw-anthropic-api-key`, an ordinary provider-sync catalog
>    entry (`auth.type: api_key`) for users with a regular Anthropic API key.
> 2. Claude Pro/Max subscription: the **built-in OpenCode `anthropic`
>    provider** pointed at the gateway at runtime via the environment, with
>    the maintained community auth plugin
>    (`@ex-machina/opencode-anthropic-auth`) registering the OAuth method.
>    There is no separate gateway provider entry for the subscription path,
>    and no repository-owned client auth plugin: the community plugin performs
>    OAuth client-side directly against Anthropic and rewrites model requests
>    to look like Claude Code (research F4: OpenCode ships no Anthropic auth
>    since 1.3.0; a plugin is required).
>
> No committed file defines, overrides, or names the built-in `anthropic`
> provider's baseURL or models. Routing for the subscription path is a
> runtime `ANTHROPIC_BASE_URL` environment variable that the community plugin
> honors, and the repository ships only a thin installer
> (`res/scripts/opencode-anthropic-max.sh`) that adds the plugin spec and
> prints the environment. Explicitly excluded: intercepting or hosting the
> client-side login on the gateway, and any modification of request bodies or
> auth headers on the passthrough route.

---

**Cross-references:**
- [SPEC-PROVIDER-ANTHROPIC](../specifications/SPEC-PROVIDER-ANTHROPIC.md): companion specification
- [RES-ANTHROPIC-OAUTH](../research/RES-ANTHROPIC-OAUTH.md): feasibility evidence
- [REQ-PROVIDER-SYNC](REQ-PROVIDER-SYNC.md): provider catalog and client-config service
- [`plugins/custom/provider-sync.lua`](../../plugins/custom/provider-sync.lua): OpenCode provider block rendering
- [`conf/providers/workspace-gw-anthropic-api-key.yaml`](../../conf/providers/workspace-gw-anthropic-api-key.yaml): API-key provider
- [`res/scripts/opencode-anthropic-max.sh`](../../res/scripts/opencode-anthropic-max.sh): community-plugin installer
- [`conf/apisix.yaml.j2`](../../conf/apisix.yaml.j2): relay route
- [`res/scripts/claude-gw.sh`](../../res/scripts/claude-gw.sh): client wrapper

---

## 1. Purpose & Scope

### 1.1 Purpose

Serve Anthropic models through WORKSPACE-GATEWAY with the client's own
Anthropic authentication passed through untouched. The gateway is a dumb
proxy; it never mints, stores, refreshes, or injects an Anthropic credential.
Two client-side authentication paths are supported without either path
requiring the gateway to handle Anthropic auth: a first-class API-key
provider, and the built-in OpenCode `anthropic` provider for Claude Pro/Max.

### 1.2 Scope

**This document OWNS the requirements for:**
- The `/anthropic/*` passthrough route and its no-auth-plugin contract
- The `workspace-gw-anthropic-api-key` provider definition
- The Claude Pro/Max path: the community auth plugin, the
  `res/scripts/opencode-anthropic-max.sh` installer, and the
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
| Subscription path | Built-in OpenCode `anthropic` provider + community auth plugin (`@ex-machina/opencode-anthropic-auth`), routed at runtime via `ANTHROPIC_BASE_URL` |
| Community plugin | The external, maintained OpenCode plugin that performs Claude Pro/Max PKCE OAuth client-side and injects the required Claude Code request shape |
| beta path | Subscription OAuth tokens require `anthropic-beta: oauth-2025-04-20`, authored client-side by the community plugin |

## 2. Functional Requirements

### FR-1: Route

| ID | Requirement |
|----|-------------|
| FR-1.1 | The gateway SHALL expose `relay-anthropic` (`/anthropic/*`) proxying to `api.anthropic.com:443` over HTTPS with path rewrite `^/anthropic/(.*)` to `/$1`. |
| FR-1.2 | Query strings (including `?beta=true`), request bodies, and response streams MUST pass through unmodified. |
| FR-1.3 | The gateway SHALL NOT expose any Anthropic login, callback, verification, or token endpoint. |

### FR-2: Transparent passthrough

| ID | Requirement |
|----|-------------|
| FR-2.1 | The `/anthropic/*` route MUST NOT run any auth-injecting or auth-stripping plugin: `Authorization`, `x-api-key`, `anthropic-beta`, `anthropic-version`, and `anthropic-organization` headers from the client MUST reach the upstream byte-identical. |
| FR-2.2 | The gateway MUST NOT custody, log, or rewrite any credential on this route beyond the standard redaction pipeline applied to all providers. |
| FR-2.3 | Client-visible behavior MUST equal talking to api.anthropic.com directly: same status codes, same error bodies, same streaming semantics. Documented client-side base-URL side effects (tool-search default, Remote Control disablement) are client behavior, not gateway defects. |
| FR-2.4 | Standard gateway observability MUST still apply: http-logger, redact, sse-usage, prometheus, request-id, limit-count, key-meta. |

### FR-3: Provider definition

| ID | Requirement |
|----|-------------|
| FR-3.1 | The repository SHALL provision exactly one Anthropic provider file, following the existing provider YAML schema and id contract, using `provider.id: anthropic` and `npm: "@anthropic-ai/sdk"`: `workspace-gw-anthropic-api-key` (auth `api_key`). |
| FR-3.2 | The provider MUST use the single `/anthropic` route; no additional gateway route, upstream, or auth surface is introduced. |
| FR-3.3 | The built-in OpenCode provider id `anthropic` MUST NOT be defined or overridden by any committed provider file or static fragment. (The subscription path selects it, but routing is injected at runtime via `ANTHROPIC_BASE_URL`, never by committed provider config.) |
| FR-3.4 | The repository MUST NOT ship a custom static-config fragment for Anthropic. The API-key provider is installed by `make setup-providers`; the subscription path is wired by `make setup-anthropic-max`. |

### FR-4: Claude Pro/Max subscription path (client-side, community plugin)

| ID | Requirement |
|----|-------------|
| FR-4.1 | The subscription path MUST use the built-in OpenCode `anthropic` provider; no separate gateway provider entry is created. |
| FR-4.2 | The repository SHALL depend on the maintained community plugin `@ex-machina/opencode-anthropic-auth`, pinned to an exact version, added to the OpenCode `plugin` array. |
| FR-4.3 | `res/scripts/opencode-anthropic-max.sh` MUST add the pinned plugin spec idempotently (preserving unrelated plugin entries) and MUST NOT modify the `anthropic` provider block. |
| FR-4.4 | The installer MUST print the runtime environment required to route model traffic through the gateway: `ANTHROPIC_BASE_URL=<gateway>/anthropic` (and `ANTHROPIC_INSECURE=1` only for a self-signed gateway cert). |
| FR-4.5 | The community plugin MUST perform the Anthropic PKCE OAuth exchange directly against Anthropic (client process); the gateway MUST NOT be involved in the authorization or token exchange. |
| FR-4.6 | After the user selects "Claude Pro/Max" on the built-in `anthropic` provider, all Anthropic model traffic MUST flow through the gateway while the credential stays client-side. |
| FR-4.7 | The repository MUST NOT ship its own Anthropic OAuth engine; OAuth and Claude Code request rewriting are the community plugin's responsibility. |

### FR-5: Client wrapper (`res/scripts/claude-gw.sh`)

| ID | Requirement |
|----|-------------|
| FR-5.1 | The wrapper MUST set exactly one environment variable, `ANTHROPIC_BASE_URL` (default a reachable gateway origin), then exec `claude` with all arguments. |
| FR-5.2 | The wrapper MUST NOT set `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, or any other credential env: external credential envs disable the CLI's OAuth path (research F1). |
| FR-5.3 | The wrapper MUST fail with an install hint when `claude` is not on PATH. |

### FR-6: Provider models & pricing

| ID | Requirement |
|----|-------------|
| FR-6.1 | Model catalog and pricing for the API-key provider SHALL sync from models.dev namespace `anthropic`; model ids MUST NOT be remapped. The subscription path uses the built-in provider's own models.dev catalog. |
| FR-6.2 | Provider display MUST use the `@anthropic-ai/sdk` npm package id for Anthropic-protocol clients. |

### FR-7: Security

| ID | Requirement |
|----|-------------|
| FR-7.1 | Anthropic credentials MUST never appear in gateway logs; the redact pipeline MUST cover OAuth token shapes. |
| FR-7.2 | The gateway MUST NOT persist any Anthropic OAuth token or pending authorization record; no Anthropic token/device prefix is provisioned in OpenBao. |
| FR-7.3 | Rate limits and key hashing MUST apply on the route exactly as on existing provider routes. |

## 3. Non-Functional Requirements

| ID | Requirement |
|----|-------------|
| NFR-1 | Passthrough streaming MUST add no measurable first-byte latency beyond transport (proxy-buffering disabled, as all SSE routes). |
| NFR-2 | The route MUST remain under the standard route plugin budget and file size limits of the repo. |
| NFR-3 | The installer script MUST pass the repo's shell lint (`bash -n`) and have a self-check for its idempotent merge. |

## 4. Acceptance

| Scenario | Expected |
|----------|----------|
| `claude` with wrapper, `/login` done once | All model traffic flows through GW with CLI-owned credentials; GW logs show anthropic models; no gateway auth errors |
| `claude` streaming request via GW | Indistinguishable from direct api.anthropic.com streaming |
| OpenCode API-key provider installed with a key | `workspace-gw-anthropic-api-key/*` chats flow through GW; gateway stores nothing |
| `make setup-anthropic-max` then `/connect` → Anthropic → Claude Pro/Max | Community plugin mints/refreshes the token against Anthropic; inference flows through GW; gateway stores nothing |
| Built-in `anthropic` provider in OpenCode | Untouched on disk; no committed file defines or overrides its baseURL |
| Gateway restart mid-session | Client refresh continues uninterrupted (client-side); no gateway state lost |
