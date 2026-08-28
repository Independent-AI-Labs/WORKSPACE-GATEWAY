# REQ-PROVIDER-OPENAI: OpenAI OAuth Relay

**Date:** 2026-08-06
**Status:** Active
**Type:** Requirements
**Specification:** [SPEC-PROVIDER-OPENAI](../specifications/SPEC-PROVIDER-OPENAI.md)

> Defines the gateway-managed OpenAI ChatGPT/Codex OAuth provider and records
> its compatibility boundary with OpenCode's native OpenAI integration. The
> gateway exposes both OpenCode-compatible OpenAI OAuth methods: browser
> authorization-code/PKCE and headless device authorization. OpenCode loads the
> gateway-owned external auth plugin; provider JSON alone does not define OAuth.

## 1. Scope

- `openai-auth` device/browser start, callback, bearer validation, refresh, and header injection
- OpenBao pending-device and OAuth-session records
- The `/openai/*` relay and `workspace-gw-openai-device-oauth` provider mapping
- Compatibility notes against `../opencode/packages/core/src/plugin/provider/openai.ts`
  and `../opencode/packages/opencode/src/plugin/openai/codex.ts`

This document does not define OpenAI model catalog or pricing synchronization.

## 2. Functional Requirements

| ID | Requirement |
|----|-------------|
| FR-1.1 | The gateway SHALL expose `relay-openai` at `/openai/*`, rewrite the path to `/backend-api/codex/responses`, and proxy HTTPS to `chatgpt.com:443`. |
| FR-1.2 | The route MUST use `openai-auth`; unauthenticated requests MUST NOT reach the upstream. |
| FR-1.3 | Device start MUST broker upstream authorization at `/openai/auth/device?session=<id>`, retain upstream state, and return an opaque gateway `device_code` with the verification payload. |
| FR-1.4 | Device polling MUST accept only the opaque gateway `{ "device_code": ... }`, resolve upstream state, and return HTTP 202 with `authorization_pending` while OpenAI reports HTTP 403 or 404. |
| FR-1.5 | A successful poll MUST exchange OpenAI's `authorization_code` and `code_verifier` at `/oauth/token`, store the session, delete the pending device record, and return `access_token`, `expires_in`, and `session_id`. |
| FR-1.6 | Proxy requests MUST require a Bearer token, resolve the session by the hash of the client-issued token, and refresh when expiry is within 300 seconds by default. |
| FR-1.7 | The plugin MUST set the refreshed upstream Bearer token, `ChatGPT-Account-Id` when available, and gateway key, tenant, and rate-limit headers. |
| FR-1.8 | `workspace-gw-openai-device-oauth` MUST use route `/openai`, OAuth plugin `openai-auth`, npm package `@ai-sdk/openai`, and models.dev provider `openai`. |
| FR-1.9 | The provider-sync response MUST identify `chatgpt-headless` with flow `device_authorization` and `chatgpt-browser` with flow `authorization_code_pkce`. |
| FR-1.10 | The gateway-owned OpenCode plugin MUST register both methods for `workspace-gw-openai-device-oauth` through OpenCode's standard `Hooks.auth` mechanism. |
| FR-1.11 | Browser OAuth MUST use OpenCode's loopback callback `http://localhost:1455/auth/callback`; the gateway MUST validate state and perform the upstream code exchange. |
| FR-1.12 | The external plugin MUST import the published `@opencode-ai/plugin` package and MUST NOT copy, re-declare, or modify OpenCode's plugin type definitions. |
| FR-1.13 | Plugin tests MUST run with the Bun runtime and preserve OpenCode's upstream `bun:test` test style. npm/Node test wrappers are not an accepted substitute. |
| FR-1.14 | The gateway repository MUST pin the published plugin package and maintain its Bun lockfile independently of the OpenCode source checkout. |

## 3. OpenCode Compatibility

OpenCode currently registers two OAuth methods for OpenAI: browser and
headless. The gateway-owned plugin registers both methods for the gateway
provider. Browser OAuth uses
`/oauth/authorize`, PKCE S256, state validation, and the loopback callback
`http://localhost:1455/auth/callback`; the callback code is submitted to
`openai-auth`, which performs the token exchange and returns a gateway-issued
client credential.

OpenCode's native requests also add `originator: opencode`, a dynamic
`opencode/<InstallationVersion> (<platform> <release>; <arch>)` User-Agent,
and `session-id`. The gateway injects `originator: opencode` and forwards
`session-id` (from the client's `session-id` or `X-OpenCode-Session-Id`
header). The User-Agent remains the pinned `opencode/1.18.3` string; a
dynamic platform User-Agent is a known compatibility gap, not a requirement
silently treated as implemented.

Additional hardening in effect: device and browser token responses MUST
include `access_token`, `refresh_token`, and a positive `expires_in`
(malformed upstream responses fail closed with a protocol error); browser
OAuth state is single-use (atomically consumed before the upstream code
exchange, replayed callbacks get 400); and a refreshed session that cannot
be persisted in OpenBao terminates the request with 503 instead of issuing
a possibly-lost rotated refresh token.

## 4. Storage and Security

- Pending records: `secret/data/gateway/openai-device/{sha256(device_code)}`.
- Pending records contain upstream device state; clients never call OpenAI device endpoints directly.
- Sessions: `secret/data/gateway/openai-tokens/{sha256(issued access_token)}`.
- Session records retain access/refresh/id tokens, expiry values, issued/live token hashes, account id, session id, and update time.
- Tokens and device codes MUST NOT be logged. Upstream traffic MUST use HTTPS.
- JWT claims are decoded for account identification and expiry; the gateway does not verify the JWT signature.

## 5. Verification Matrix

| Test | Coverage |
|------|----------|
| `tests/config/test_apisix_yaml.sh` | OpenAI relay route and plugin wiring |
| `tests/integration/test_provider_sync_client.sh` | OpenAI provider detail and OpenCode mapping |
| `tests/scripts/test_opencode_provider_login.sh` | Legacy device-flow installer behavior |
| `res/opencode-plugin/workspace-gateway-auth.ts` | Native OpenCode browser/device method registration |
| `res/opencode-plugin/workspace-gateway-auth.test.ts` | Plugin method/device/browser callback unit tests |

## 6. Implementation Status

| Item | Status | Evidence |
|------|--------|----------|
| Relay and rewrite | Implemented | `conf/apisix.yaml`, `relay-openai` |
| OAuth plugin | Implemented | `plugins/custom/openai-auth.lua` |
| OpenAI handshake and refresh | Implemented | `plugins/custom/openai_device.lua` |
| Provider definition | Implemented | `conf/providers/workspace-gw-openai-device-oauth.yaml` |
| Browser PKCE OAuth parity | Implemented | `openai-auth.lua`, `openai_device.lua`, and gateway-owned OpenCode plugin |
| OpenCode auth method registration | Implemented | `res/opencode-plugin/workspace-gateway-auth.ts` and example config; methods are registered from provider-sync `auth_methods` metadata, dispatched by flow |
| OpenCode request-header parity | Implemented | `openai-auth.lua` injects `originator` and forwards `session-id`; dynamic platform User-Agent remains pinned |
| Published plugin dependency and Bun workspace metadata | Implemented | `res/opencode-plugin/package.json`, `bun.lock`, `tsconfig.json`, Make targets, and generated CI hooks (landed in `d41db07`) |
| Device polling pending-response handling | Implemented | `workspace-gateway-auth.ts` accepts HTTP 202; Bun tests cover pending and `slow_down` (landed in `d41db07`) |
| Single-use browser state and terminal refresh persistence | Implemented | `kimi_tokens.consume_device`, `oauth_session.ensure_fresh` |
