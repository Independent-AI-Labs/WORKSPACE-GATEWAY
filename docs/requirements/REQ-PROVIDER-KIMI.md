# REQ-PROVIDER-KIMI: Moonshot Kimi Provider (OAuth Device Code + API Proxy)

**Date:** 2026-07-17
**Status:** Active
**Type:** Requirements
**Specification:** [SPEC-PROVIDER-KIMI](../specifications/SPEC-PROVIDER-KIMI.md)

> Mandates the Moonshot Kimi integration: RFC 8628 device-code OAuth managed by
> the `kimi-auth` plugin, token custody in OpenBao with transparent refresh, and
> three first-class access modes (OAuth, federated virtual key, own API key)
> across 6 Kimi relay routes to `api.kimi.com/coding/v1`. Explicitly excluded:
> the Kimi local server relay, ACP bridging, and browser/PKCE flows.

---

**Cross-references:**
- [SPEC-PROVIDER-KIMI](../specifications/SPEC-PROVIDER-KIMI.md): companion specification
- [`plugins/custom/kimi-auth.lua`](../../plugins/custom/kimi-auth.lua): device start/poll/proxy phases
- [`plugins/custom/kimi_device.lua`](../../plugins/custom/kimi_device.lua): OAuth HTTP helpers
- [`plugins/custom/kimi_jwt.lua`](../../plugins/custom/kimi_jwt.lua): JWT decode/expiry/hash
- [`plugins/custom/kimi_tokens.lua`](../../plugins/custom/kimi_tokens.lua): OpenBao token storage
- [`conf/apisix.yaml`](../../conf/apisix.yaml): 6 `relay-kimi*` routes
- [`conf/providers/workspace-gw-kimi-oauth.yaml`](../../conf/providers/workspace-gw-kimi-oauth.yaml) and siblings: provider definitions

---

## 1. Purpose & Scope

### 1.1 Purpose

Provide OpenAI-compatible access to Kimi models through the gateway with
gateway-managed OAuth sessions (clients hold a static access token; the gateway
refreshes transparently) and two API-key alternatives.

### 1.2 Scope

**This document OWNS the requirements for:**
- Device-code OAuth handshake endpoints (`/kimi/auth/device`, `/kimi/auth/device/poll`)
- `kimi-auth` proxy authentication, session lookup, and automatic refresh
- OpenBao storage layout for device records and OAuth sessions
- The 6 Kimi relay routes and their auth mode assignment
- The three client access modes and their OpenCode provider ids

**This document DOES NOT:**
- Define virtual-key resolution internals (owned by `key-resolver`)
- Specify model catalog/pricing sync (owned by REQ-PROVIDER-SYNC)
- Cover Kimi local server or ACP integrations

### 1.3 Terminology

| Term | Definition |
|------|------------|
| OAuth mode | Client sends gateway-issued OAuth `access_token` JWT on `/kimi/*` |
| Federated mode | Client sends `vgw-*` virtual key on `/kimi-federated/*`; gateway resolves to `KIMI_API_KEY` in OpenBao |
| Own-key mode | Client sends own `sk-...` on `/kimi-key/*`; gateway passes it through |
| session_id | Handshake correlation label (`?session=`); never required on API calls |
| token_hash | hex sha256 of the issued access token; the OpenBao session key |

## 2. Functional Requirements

### FR-1: Access Modes & Routes

| ID | Requirement |
|----|-------------|
| FR-1.1 | The gateway SHALL expose 6 Kimi routes: `relay-kimi` (`/kimi/*`), `relay-kimi-v1` (`/kimi/v1/*`), `relay-kimi-federated` (`/kimi-federated/*`), `relay-kimi-federated-v1` (`/kimi-federated/v1/*`), `relay-kimi-key` (`/kimi-key/*`), `relay-kimi-key-v1` (`/kimi-key/v1/*`). |
| FR-1.2 | All 6 routes MUST proxy to `api.kimi.com:443` over HTTPS and rewrite the path to `/coding/v1/*`. |
| FR-1.3 | `/kimi/*` routes MUST use `kimi-auth` (not `key-resolver`); `/kimi-federated/*` routes MUST use `key-resolver` with `upstream_key_env: KIMI_API_KEY` and `virtual_key_prefix: vgw-`; `/kimi-key/*` routes MUST use no auth plugin. |
| FR-1.4 | Console API keys (`sk-...`) MUST be rejected on `/kimi/*` with a pointer to `/kimi-key`; `sk-` keys MUST NOT be accepted on `/kimi-federated/*`. |
| FR-1.5 | The device endpoints `/kimi/auth/device` and `/kimi/auth/device/poll` MUST be handled inside `kimi-auth` before any upstream proxying. |

### FR-2: Device-Code OAuth

| ID | Requirement |
|----|-------------|
| FR-2.1 | Device authorization MUST POST `{oauth_host}/api/oauth/device_authorization` with `client_id` `17e5f671-d194-4dfb-9706-5516cb48c098` and no PKCE/redirect. |
| FR-2.2 | Device start MUST store a pending record in OpenBao under `secret/data/gateway/kimi-device/{sha256(device_code)}` and return `{ verification_uri, verification_uri_complete, user_code, device_code, interval, expires_in }`. |
| FR-2.3 | Device poll MUST accept `device_code` in a JSON body, verify the pending record exists and is unexpired, and POST the token endpoint with `grant_type=urn:ietf:params:oauth:grant-type:device_code`. |
| FR-2.4 | On `authorization_pending`/`slow_down` the poll MUST return 202 without consuming the device code. |
| FR-2.5 | On success the poll MUST store the session under `sha256(issued access_token)`, delete the pending device record, and return `{ access_token, expires_in, account, session_id }`. |
| FR-2.6 | All calls to Kimi OAuth infrastructure MUST send `User-Agent: Kimi CLI (Linux 6.17.0-35-generic x64)`. |

### FR-3: Proxy Authentication & Refresh

| ID | Requirement |
|----|-------------|
| FR-3.1 | `/kimi/*` MUST require an `Authorization: Bearer` header; missing header MUST yield 401. |
| FR-3.2 | Bearer tokens starting with `sk-` MUST yield 401 with a `/kimi-key` pointer. |
| FR-3.3 | The session MUST be looked up by `sha256(bearer)`, else JWT-`sub` lookup for rotated tokens; no session MUST yield 401 `session not found; run device flow first`. |
| FR-3.4 | When the stored access token expires within `refresh_threshold` (default 300s), the plugin MUST refresh via `grant_type=refresh_token` and update the same session record (keyed by the original issued token hash). |
| FR-3.5 | On `invalid_grant` during refresh, the plugin MUST delete the session and return 401 `re-authenticate`; on transient refresh failure it MUST return 503. |
| FR-3.6 | On OpenBao unavailability, the plugin MUST return 503 `cannot reach token store`. |
| FR-3.7 | The plugin MUST set upstream `Authorization: Bearer <fresh token>` and gateway meta headers `X-Gateway-Key-Id`, `X-Gateway-User-Id`, `X-Gateway-Tenant-Id`, `X-Gateway-Rate-Limit-RPM`, `X-Gateway-Rate-Limit-Window`, plus `ctx.consumer.username`. |
| FR-3.8 | The plugin MUST NOT rewrite the request body. |

### FR-4: OpenBao Storage

| ID | Requirement |
|----|-------------|
| FR-4.1 | Pending device records MUST live at `secret/data/gateway/kimi-device/{device_code_hash}` and MUST be deleted after successful exchange or expiry. |
| FR-4.2 | OAuth sessions MUST live at `secret/data/gateway/kimi-tokens/{token_hash}` where `token_hash = sha256(issued access_token)`. |
| FR-4.3 | Session records MUST retain `access_token`, `refresh_token`, `expires_at`, `issued_access_token_hash`, `live_access_token_hash`, `sub`, and `session_id`; refresh MUST update the record under the original issued-hash key so the client's token string keeps working. |
| FR-4.4 | Access/refresh tokens MUST NOT be logged. |

### FR-5: OpenCode Provider Mapping

| ID | Requirement |
|----|-------------|
| FR-5.1 | Three OpenCode provider ids MUST exist: `workspace-gw-kimi-oauth` (`/kimi`, auth `oauth`), `workspace-gw-kimi-private` (`/kimi-federated`, auth `virtual_key`), `workspace-gw-kimi-own` (`/kimi-key`, auth `none`). |
| FR-5.2 | All three MUST source models from models.dev provider `moonshotai` with `strip_prefix: moonshotai/` + `lowercase` normalization and `cost_source: moonshotai`. |

## 3. Non-Functional Requirements

| ID | Requirement |
|----|-------------|
| NFR-1.1 | Token refresh MUST be invisible to the client (no client-side refresh logic required). |
| NFR-1.2 | OAuth and API hosts MUST be HTTPS on `kimi.com` domains (or configured overrides). |

## 4. Constraints

| ID | Constraint | Source |
|----|------------|--------|
| C-1 | RFC 8628 device code only; no PKCE/browser redirect | kimi-code oauth source |
| C-2 | `kimi-auth` priority 2560 (before key-meta 2530) | plugins/custom/kimi-auth.lua |
| C-3 | Device code TTL 900s; single-use | legacy kimi spec §9 |

## 5. Assumptions

| ID | Assumption |
|----|------------|
| A-1 | Kimi managed endpoints are fully OpenAI-compatible; `sse-usage`/`cost_calc` need no Kimi-specific changes. |
| A-2 | JWT claim decoding does not verify signatures (gateway trusts its own issued tokens). |

## 6. Open Questions

None. (Resolved: three-mode split; OAuth sessions keyed by issued-token hash;
`sk-` rejection on `/kimi/*` with explicit `/kimi-key` passthrough.)

## 7. Verification Matrix

| # | Test | Maps to |
|---|------|---------|
| V1 | [`tests/lua/test_kimi_jwt.lua`](../../tests/lua/test_kimi_jwt.lua) | FR-3.x (claim decode, expiry, hash) |
| V2 | [`tests/config/test_apisix_yaml.sh`](../../tests/config/test_apisix_yaml.sh) | FR-1.1-FR-1.3 |
| V3 | [`tests/integration/test_route_relay.sh`](../../tests/integration/test_route_relay.sh) | FR-1.x |
| V4 | [`tests/integration/test_provider_sync_client.sh`](../../tests/integration/test_provider_sync_client.sh) | FR-2.x device-flow timeout handling |

## 8. Implementation Status

| Item | Status | Evidence |
|------|--------|----------|
| FR-1.x 6 routes | Implemented | conf/apisix.yaml `relay-kimi*` |
| FR-2.x device flow | Implemented | kimi-auth.lua, kimi_device.lua |
| FR-3.x proxy auth + refresh | Implemented | kimi-auth.lua `plugin.access` |
| FR-4.x OpenBao storage | Implemented | kimi_tokens.lua |
| FR-5.x provider YAMLs | Implemented | conf/providers/workspace-gw-kimi-*.yaml |
