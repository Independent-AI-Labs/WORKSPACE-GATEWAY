# REQ-PROVIDER-OPENAI: OpenAI OAuth Relay

**Date:** 2026-08-04
**Status:** Active
**Type:** Requirements
**Specification:** [SPEC-PROVIDER-OPENAI](../specifications/SPEC-PROVIDER-OPENAI.md)

> Defines the gateway-managed OpenAI ChatGPT/Codex OAuth provider and records
> its compatibility boundary with OpenCode's native OpenAI integration. The
> gateway currently implements OpenCode's headless device flow, not its browser
> PKCE flow.

## 1. Scope

- `openai-auth` device start, poll, bearer validation, refresh, and header injection
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
| FR-1.9 | The provider-sync response MUST identify the implemented method as `chatgpt-headless` with flow `device_authorization`; browser PKCE remains a separate unimplemented method. |

## 3. OpenCode Compatibility

OpenCode currently registers two OAuth methods for OpenAI: browser and
headless. The gateway implements only the headless method. Browser OAuth uses
`/oauth/authorize`, PKCE S256, state validation, and the loopback callback
`http://localhost:1455/auth/callback`; it is not available through
`openai-auth`.

OpenCode's native requests also add `originator: opencode`, a dynamic
`opencode/<InstallationVersion> (<platform> <release>; <arch>)` User-Agent,
and `session-id`. The gateway currently injects only the Bearer credential,
`ChatGPT-Account-Id` when discoverable, and gateway metadata. These are known
compatibility gaps, not requirements silently treated as implemented.

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
| `tests/scripts/test_opencode_provider_login.sh` | Generic OAuth device-flow client behavior |

## 6. Implementation Status

| Item | Status | Evidence |
|------|--------|----------|
| Relay and rewrite | Implemented | `conf/apisix.yaml`, `relay-openai` |
| OAuth plugin | Implemented | `plugins/custom/openai-auth.lua` |
| OpenAI handshake and refresh | Implemented | `plugins/custom/openai_device.lua` |
| Provider definition | Implemented | `conf/providers/workspace-gw-openai-device-oauth.yaml` |
| Browser PKCE OAuth parity | Not implemented | No browser authorization route in `openai-auth.lua` |
| OpenCode request-header parity | Partial | `openai-auth.lua` omits `originator` and `session-id` |
