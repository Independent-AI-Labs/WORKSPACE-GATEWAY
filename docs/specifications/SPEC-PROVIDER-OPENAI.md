# SPEC-PROVIDER-OPENAI: OpenAI OAuth Provider

**Date:** 2026-08-06
**Status:** Active
**Type:** Specification
**Requirements:** [REQ-PROVIDER-OPENAI](../requirements/REQ-PROVIDER-OPENAI.md)

**Upstream reference:** `../opencode/packages/core/src/plugin/provider/openai.ts`
and `../opencode/packages/opencode/src/plugin/openai/codex.ts`

**External plugin package:** published `@opencode-ai/plugin`
(`1.18.14` observed on 2026-08-06; the gateway pins the version in its own
Bun manifest and lockfile).

## 1. Components

| Component | Responsibility |
|-----------|----------------|
| `oauth-auth` (generic plugin, OpenAI config set: `protocol: chatgpt_device`) | APISIX access-phase device flow, session lookup, refresh, and header injection |
| `oauth_device.lua` | Protocol engines; `chatgpt_device` covers OpenAI device authorization, poll, authorization-code exchange, and refresh HTTP calls |
| `oauth_jwt.lua` | Token hashing, expiry checks, and JWT claim decoding |
| `oauth_store.lua` | OpenBao KVv2 device/session CRUD |
| `relay-openai` | HTTPS relay from `/openai/*` to ChatGPT Codex responses |
| `workspace-gateway-auth.ts` | Gateway-owned OpenCode `Hooks.auth` adapter using the published plugin package |

## 2. OAuth Protocol

The gateway brokers the device flow. It does not expose OpenAI's
`device_auth_id` or require clients to call OpenAI's device endpoints directly.
The client receives an opaque gateway device-session code (`gw-<sha256>` of
request-unique material, minted by `oauth_broker.gateway_device_code`);
upstream device state remains in the gateway's pending OpenBao record.

| Constant | Value |
|----------|-------|
| OAuth host | `https://auth.openai.com` |
| Client id | `app_EMoamEEZ73f0CkXaXp7hrann` |
| Device start | JSON `POST /api/accounts/deviceauth/usercode` |
| Browser URI | `https://auth.openai.com/codex/device` |
| Device poll | JSON `POST /api/accounts/deviceauth/token` |
| Token exchange | Form `POST /oauth/token` |
| Redirect URI | `https://auth.openai.com/deviceauth/callback` |
| Refresh | Form `POST /oauth/token` with `grant_type=refresh_token` |
| Gateway OAuth HTTP User-Agent | `opencode/1.18.3` (currently hard-coded) |
| Refresh threshold | 300 seconds |

The device-start body is `{ "client_id": <client id> }`. Polling sends
`{ "device_auth_id": <device code>, "user_code": <user code> }`. OpenAI's
successful poll response supplies `authorization_code` and `code_verifier`;
those are exchanged using `grant_type=authorization_code`, `code`,
`redirect_uri`, `client_id`, and `code_verifier`. HTTP 403/404 from the poll
endpoint is treated as pending. This is intentionally documented separately
from Kimi's RFC 8628 grant and form device-token exchange.

OpenCode also supports a separate browser method. The upstream implementation
generates PKCE and state,
opens `/oauth/authorize` with `scope=openid profile email offline_access`,
`id_token_add_organizations=true`, `codex_cli_simplified_flow=true`, and
`originator=opencode`, then receives the code at
`http://localhost:1455/auth/callback`. The gateway-owned plugin exposes this
method through `oauth-auth`; the plugin submits the callback code and state to
the gateway, which performs the upstream exchange. This upstream contract was
verified against OpenCode source on 2026-08-06.

The gateway plugin remains an external project-owned file. It MUST import
`@opencode-ai/plugin` from the public package registry through Bun. It MUST NOT
copy the plugin module, re-declare its exported types, or modify the sibling
`projects/opencode` checkout. Its tests remain Bun tests using `bun:test`.

## 3. Request Processing

1. `/openai/auth/device` requests upstream authorization, stores the pending broker record, and returns the gateway device payload.
2. `/openai/auth/device/poll` resolves the gateway device code, polls OpenAI, exchanges the authorization result, stores the session, and removes the pending record.
3. Other `/openai/*` requests resolve the client Bearer token by `sha256(token)`.
4. Near expiry, the plugin refreshes the upstream token while preserving the original client-token lookup key.
5. The plugin sets `Authorization: Bearer <live token>` and, when present, `ChatGPT-Account-Id` from `chatgpt_account_id` or the first organization id in the token claims.

Gateway metadata includes `X-Gateway-Key-Id`, `X-Gateway-Tenant-Id`,
`X-Gateway-Rate-Limit-RPM: 100`, and `X-Gateway-Rate-Limit-Window: 60`,
set through the shared `oauth_session.set_meta_headers` helper.

The plugin injects `originator: opencode` and forwards a client-supplied
`session-id` (or `X-OpenCode-Session-Id`). Unlike OpenCode's native hook,
the User-Agent stays the pinned `opencode/1.18.3`; a dynamic platform
User-Agent remains a divergence (see §6).

Browser OAuth state is single-use: `oauth_store.consume_device` atomically
DELETEs the pending record before the upstream code exchange, so a replayed
or concurrent callback receives 400. A failed exchange consumes the state;
the client restarts the browser login. Session refresh and persistence run
through the shared `oauth_session.ensure_fresh` helper: unknown expiry
(neither JWT `exp` nor stored `expires_at`) fails closed into a refresh, and
a refresh that cannot be persisted terminates with 503 rather than issuing
a possibly-lost rotated refresh token.

## 4. Route and Provider

| Route | URI | Rewrite | Auth |
|-------|-----|---------|------|
| `relay-openai` | `/openai/*` | `^/openai/(.*)` -> `/backend-api/codex/responses` | `oauth-auth` |

The provider file `workspace-gw-openai-device-oauth.yaml` declares
`workspace-gw-openai-device-oauth`, route `/openai`, `@ai-sdk/openai`, OAuth auth via
`oauth-auth`, and models.dev provider `openai`.

## 5. Failure Behavior

| Condition | Status | Result |
|-----------|--------|--------|
| Missing device code | 400 | `oauth-auth: missing device_code` |
| Missing/expired device record | 400 | Device session error |
| OpenAI poll still pending | 202 | `authorization_pending` |
| Device/token upstream failure | 502 | OpenAI auth error |
| Malformed token response (missing refresh_token/expires_in) | 502 | Protocol error (fail closed) |
| Replayed or concurrent browser callback | 400 | Browser session expired, invalid, or already used |
| Missing or unknown Bearer session | 401 | Authentication error |
| Refresh `invalid_grant` | 401 | Session deleted; re-authentication required |
| Other refresh failure | 503 | Token refresh failure |
| Refreshed session not persistable | 503 | Token-store failure (refresh result refused) |
| OpenBao write failure | 503 | Token-store failure |

## 6. Known Divergences

- The gateway hard-codes `opencode/1.18.3`; OpenCode uses its current
  `InstallationVersion`. `originator` and `session-id` are now injected, so
  the remaining header divergence is the dynamic platform User-Agent.
- Device and browser token responses are validated strictly (non-empty
  `access_token` and `refresh_token`, positive `expires_in`); only the
  refresh path may retain a previous refresh token when the upstream omits it.
- OpenCode waits for the device polling interval plus a 3-second safety
  margin; the gateway client controls polling and does not add that margin.
- The gateway returns a plain `/codex/device` value as
  `verification_uri_complete`, rather than constructing a code-bearing URL.
- Device polling must preserve the upstream pending contract: HTTP 202 with
  `authorization_pending` is a normal intermediate result, not a failed
  gateway request.

## 7. External Plugin Packaging Contract

The gateway-owned plugin is distributed from this repository and loaded by
OpenCode through a local file URL. Its package boundary is deliberately
separate from the OpenCode source tree:

| Item | Contract |
|------|----------|
| Runtime | Bun 1.3.14, pinned by the gateway package manifest |
| Public dependency | Published `@opencode-ai/plugin` package |
| Test runner | `bun test` with `bun:test` |
| Source ownership | `WORKSPACE-GATEWAY/res/opencode-plugin/` |
| Forbidden change | Copying or editing `projects/opencode/packages/plugin` |
| Lockfile ownership | `WORKSPACE-GATEWAY/res/opencode-plugin/bun.lock` |

The package setup is complete only when `bun install --frozen-lockfile`,
`bun run typecheck`, and the plugin unit test pass without using a workspace
dependency or path import into `projects/opencode`.
