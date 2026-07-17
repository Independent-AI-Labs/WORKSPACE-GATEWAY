# REQ-PROVIDER-XAI: xAI Grok Provider (OAuth PKCE + API Proxy)

**Date:** 2026-07-17
**Status:** Draft
**Type:** Requirements
**Specification:** [SPEC-PROVIDER-XAI](../specifications/SPEC-PROVIDER-XAI.md)

> This document mandates the intended design of the xAI Grok provider
> integration: OAuth 2.0 PKCE authentication (browser loopback + manual paste,
> device code) against `auth.x.ai`, gateway-held refresh tokens in OpenBao,
> and proxying of `/grok/*` to `api.x.ai/v1/*` with automatic token refresh
> via a custom `xai-auth` plugin. It is the xAI analog of the implemented
> Kimi provider (REQ-PROVIDER-KIMI). Nothing in this document is implemented
> in the current codebase.

---

**Cross-references:**
- [SPEC-PROVIDER-XAI](../specifications/SPEC-PROVIDER-XAI.md): companion specification
- REQ-PROVIDER-KIMI: implemented analog provider ([`plugins/custom/kimi-auth.lua`](../../plugins/custom/kimi-auth.lua))
- Legacy PROVIDER-XAI-GROK design (AMI-PROP-LLMGW-PROVIDER-XAI-GROK-v1.1, absorbed)
- [`docs/architecture/README.md`](../architecture/README.md): architecture hub

---

## 1. Purpose & Scope

### 1.1 Purpose

Define the requirements for adding xAI Grok models to the gateway with OAuth
as the primary credential path (SuperGrok / X Premium+ subscriptions) and an
optional console API-key passthrough. The client workflow is: run the OAuth
handshake once, paste the resulting OAuth `access_token` JWT into the
client's normal credential slot, then use the gateway as a standard
OpenAI-compatible endpoint at `http://gateway:9080/grok`.

### 1.2 Scope

**This document OWNS the requirements for:**
- The `xai-auth` custom APISIX plugin (login, complete, device, proxy phases)
- OAuth 2.0 PKCE protocol behavior against `auth.x.ai` (per official `xai-org/grok-build`)
- OpenBao token/PKCE/session storage layout
- `/grok/*` route set and proxy behavior to `api.x.ai`
- Token refresh and stale-token acceptance semantics

**This document DOES NOT:**
- Reuse `vgw-` virtual keys, `key-resolver`, or `secret/data/gateway/keys/` for Grok OAuth
- Cover the `cli-chat-proxy.grok.com` coding proxy or `X-XAI-Token-Auth` session header
- Cover enterprise customer OIDC or public non-loopback redirect URI registration
- Require changes to `sse-usage` / `cost_calc` (xAI chat completions are fully OpenAI-compatible)

### 1.3 Terminology

| Term | Definition |
|------|------------|
| `session_id` | Admin-chosen handshake correlation label; never required on API calls |
| `access_token` | OAuth JWT from xAI; the client's Bearer credential |
| `token_hash` | hex sha256 of the raw access token string; OpenBao lookup key |
| PKCE state | `{verifier, challenge, session_id, redirect_uri, nonce}` with 300s TTL |
| Refresh skew | Proactive refresh window, default 300s before expiry |

## 2. Functional Requirements

### FR-1: OAuth Handshake

| ID | Requirement |
|----|-------------|
| FR-1.1 | The gateway MUST expose `GET /grok/auth/login` which generates PKCE verifier/challenge/state/nonce, stores state in OpenBao with 300s TTL, and returns a 302 or HTML with the authorize URL. |
| FR-1.2 | The authorize URL MUST follow the official shape: `response_type=code`, `client_id`, loopback `redirect_uri=http://127.0.0.1:{port}/callback`, `scope`, `code_challenge` (S256), `state`, `nonce`, `referrer=grok-build`; it MUST NOT include `plan=`. |
| FR-1.3 | The gateway MUST expose `/grok/auth/complete` accepting a pasted callback URL, query fragment, or bare code, and MUST perform a standard PKCE token exchange (`code_verifier` only; it MUST NOT echo `code_challenge`/`code_challenge_method`). |
| FR-1.4 | On successful exchange the gateway MUST persist tokens in OpenBao, delete the PKCE state (single use), and return the `access_token` (JSON, or minimal copy-friendly HTML). |
| FR-1.5 | The gateway MUST support RFC 8628 device code flow via `POST /grok/auth/device` (returns `verification_uri`, `user_code`, `device_code`, `interval`) and `POST /grok/auth/device/poll`. |

### FR-2: Protocol Constants

| ID | Requirement |
|----|-------------|
| FR-2.1 | `CLIENT_ID` MUST default to `b1a00492-073a-47ea-816f-4c329264a828` (official public client). |
| FR-2.2 | `ISSUER` MUST be `https://auth.x.ai` with discovery at `/.well-known/openid-configuration` and hardcoded authorize/token endpoint fallbacks. |
| FR-2.3 | Minimum scope MUST be `openid profile email offline_access grok-cli:access api:access`. |
| FR-2.4 | Redirect host MUST be `127.0.0.1` with path `/callback` for the official client_id. |
| FR-2.5 | OIDC discovery endpoints MUST be pinned to HTTPS on `x.ai` / `*.x.ai`; other endpoints MUST be rejected before sending refresh tokens. |

### FR-3: Proxy Behavior

| ID | Requirement |
|----|-------------|
| FR-3.1 | `relay-grok` (`/grok/*`) MUST rewrite to `/v1/*` and proxy to `api.x.ai:443` over HTTPS with `pass_host: node`. |
| FR-3.2 | A Bearer credential starting with `xai-` MUST be passed through unchanged (console API key side door; no refresh storage). |
| FR-3.3 | A JWT Bearer credential MUST be resolved by `sha256(credential)` or JWT `sub`; if expiring within `skew_seconds` (default 300) the gateway MUST refresh proactively and send the fresh access token upstream. |
| FR-3.4 | After refresh rotation the gateway MUST keep accepting the originally issued access token string (hash alias to the same record); re-auth is required only when refresh fails (`invalid_grant` / 401). |
| FR-3.5 | The plugin MUST set `X-Gateway-Key-Id`, `X-Gateway-User-Id`, optional `X-Gateway-Tenant-Id`, and `ctx.consumer.username` for downstream plugins. |
| FR-3.6 | The plugin MUST NOT rewrite the request body; only `Authorization` and gateway meta headers change. |
| FR-3.7 | Unknown or missing credentials MUST yield 401 with a hint to re-run login/device flow. |

### FR-4: Storage

| ID | Requirement |
|----|-------------|
| FR-4.1 | PKCE pending state MUST live at `secret/data/gateway/xai-pkce/{state}` with 300s TTL. |
| FR-4.2 | OAuth sessions MUST be stored at `secret/data/gateway/xai-tokens/{token_hash}` including `tokens`, `issued_access_token_hash`, `live_access_token_hash`, `sub`, `session_id`, `account`, discovery endpoints, and `client_id`. |
| FR-4.3 | Secondary indexes `xai-tokens-by-sub/{sub}` and `xai-sessions/{session_id}` SHOULD point at the primary record. |
| FR-4.4 | Concurrent refreshes SHOULD be serialized with `resty.lock` on `token_hash`/`sub`; on refresh_token rotation conflicts the session MUST be cleared and 401 returned. |

### FR-5: Routes

| ID | Requirement |
|----|-------------|
| FR-5.1 | Route `xai-auth-login` MUST serve `/grok/auth/login`. |
| FR-5.2 | Route `xai-auth-complete` MUST serve `/grok/auth/complete` (GET, POST). |
| FR-5.3 | Route `xai-auth-device` MUST serve `/grok/auth/device` and `/grok/auth/device/poll`. |
| FR-5.4 | Route `relay-grok` MUST serve `/grok/*` with the existing plugin stack (`proxy-rewrite`, `key-meta`, `redact`, `sse-usage`, etc.) plus `xai-auth`; Grok routes MUST use `xai-auth` only, not `key-resolver`. |

## 3. Non-Functional Requirements

| ID | Requirement |
|----|-------------|
| NFR-1.1 | Access and refresh tokens MUST NEVER be logged (covered by the `redact` plugin). |
| NFR-1.2 | PKCE state MUST be single-use and expire after 300s. |
| NFR-1.3 | The client-held access token MUST be treated as a secret equal to an API key (HTTPS only, hashed for storage paths). |
| NFR-1.4 | OIDC discovery SHOULD be cached for 1h in a `lua_shared_dict xai_cache 5m`. |
| NFR-1.5 | Usage/cost tracking MUST remain unchanged: OpenAI-compatible path -> `sse-usage` -> Vector -> ClickHouse, `cost_source = computed`. |

## 4. Constraints

| ID | Constraint | Source |
|----|------------|--------|
| C-1 | Plugin priority 2560 (before `key-meta` 2530) | legacy xai spec §4.1 |
| C-2 | No `vgw-` keys in the Grok OAuth flow | legacy xai spec §1.3 |
| C-3 | Standard PKCE exchange only (no challenge echo) | legacy xai spec §3.5 |
| C-4 | Loopback redirect only for the official public client_id | legacy xai spec §9.3 |

## 5. Assumptions

| ID | Assumption |
|----|------------|
| A-1 | The official public `CLIENT_ID` remains usable by third-party tooling. |
| A-2 | OpenBao is reachable from the APISIX worker via `OPENBAO_TOKEN`. |
| A-3 | `/v1/chat/completions` on xAI stays OpenAI-compatible (no parser changes needed). |

## 6. Open Questions

| Q | Resolution |
|---|------------|
| Optional official `grok` external auth provider wrapper | Later enhancement: script prints status on stderr, token JSON on stdout |
| `/v1/responses` usage parsing | Out of scope v1 |

## 7. Verification Matrix

| # | Test | Maps to |
|---|------|---------|
| V1 | Unit: PKCE verifier/challenge generation (32 random bytes, S256) | FR-1.1 |
| V2 | Unit: token exchange form omits challenge fields | FR-1.3 |
| V3 | Unit: pasted callback parsing (full URL, fragment, bare code) | FR-1.3 |
| V4 | Unit: `is_expiring` with skew | FR-3.3 |
| V5 | Integration: device flow end-to-end against mock token endpoint | FR-1.5 |
| V6 | Integration: stale access token still resolves after refresh rotation | FR-3.4 |
| V7 | Integration: unknown Bearer yields 401 | FR-3.7 |
| V8 | Integration: discovery endpoint pinning rejects non-x.ai hosts | FR-2.5 |

## 8. Implementation Status

| Item | Status | Evidence |
|------|--------|----------|
| FR-1.x OAuth handshake endpoints | Not implemented | no `plugins/custom/xai-auth.lua`; no `/grok/auth/*` routes in `conf/apisix.yaml` |
| FR-2.x protocol constants module | Not implemented | no `xai_pkce.lua` / `xai_oidc.lua` in `plugins/custom/` |
| FR-3.x proxy/refresh behavior | Not implemented | no `xai_tokens.lua` / `xai_jwt.lua` in `plugins/custom/` |
| FR-4.x OpenBao storage | Not implemented | no `xai-*` paths referenced anywhere in repo |
| FR-5.x routes | Not implemented | `conf/apisix.yaml` contains no `xai-auth` or `/grok` route |
| Plugin registration | Not implemented | `conf/config.yaml` `plugins:` list contains no `xai-auth` |
| Tests | Not implemented | no `tests/**` referencing xai/grok |
