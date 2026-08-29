# SPEC-PROVIDER-KIMI: Moonshot Kimi Provider Implementation

**Date:** 2026-07-17
**Status:** Active
**Type:** Specification
**Requirements:** [REQ-PROVIDER-KIMI](../requirements/REQ-PROVIDER-KIMI.md)

> Implements the Moonshot Kimi provider: RFC 8628 device-code OAuth via the
> `oauth-auth` plugin (priority 2560), OpenBao-backed session storage with
> transparent refresh, and 6 relay routes to `api.kimi.com/coding/v1` covering
> three access modes (OAuth, federated virtual key, own API key). Architecture
> context: [architecture/README.md](../architecture/README.md).

---

**Cross-references:**
- [REQ-PROVIDER-KIMI](../requirements/REQ-PROVIDER-KIMI.md): requirements
- [architecture/README.md](../architecture/README.md): gateway architecture hub
- [`plugins/custom/oauth-auth.lua`](../../plugins/custom/oauth-auth.lua): plugin phases
- [`plugins/custom/oauth_device.lua`](../../plugins/custom/oauth_device.lua): OAuth HTTP helpers (`request_device_authorization`, `poll_device_token`, `refresh_access_token`)
- [`plugins/custom/oauth_jwt.lua`](../../plugins/custom/oauth_jwt.lua): `decode_claims`, `expires_at`, `is_expiring`, `subject`, `token_hash`
- [`plugins/custom/oauth_store.lua`](../../plugins/custom/oauth_store.lua): OpenBao CRUD for device + session records
- [`conf/apisix.yaml`](../../conf/apisix.yaml): 6 `relay-kimi*` routes
- [`conf/providers/workspace-gw-kimi-device-oauth.yaml`](../../conf/providers/workspace-gw-kimi-device-oauth.yaml), [`-api-key`](../../conf/providers/workspace-gw-kimi-api-key.yaml), [`-virtual-key`](../../conf/providers/workspace-gw-kimi-virtual-key.yaml): provider definitions

---

## 1. Overview

```mermaid
graph TB
    U[User browser] --> AUTH[auth.kimi.com]
    C[Client] -->|Bearer access_token| KA[oauth-auth 2560]
    KA --> OB[(OpenBao kimi-tokens/ kimi-device/)]
    KA -->|refresh if near exp| AUTH
    KA --> PRW[proxy-rewrite /kimi/* -> /coding/v1/*]
    PRW --> API[api.kimi.com]
    C -->|vgw-*| KR[key-resolver] --> PRW2[/kimi-federated/* -> /coding/v1/*] --> API
    C -->|sk-...| PK[/kimi-key/* passthrough] --> API
```

No new containers: `oauth-auth` runs in the APISIX Lua worker; OpenBao stores
device and session records.

## 2. Architectural Principles

### 2.1 Three first-class modes, never mixed

| Mode | Route | Auth plugin | Secret custody | OpenCode id |
|------|-------|-------------|----------------|-------------|
| Device OAuth (managed) | `/kimi/*`, `/kimi/v1/*` | `oauth-auth` | Gateway (OpenBao holds refresh_token) | `workspace-gw-kimi-device-oauth` |
| Virtual key | `/kimi-federated/*`, `/kimi-federated/v1/*` | `key-resolver` (`KIMI_API_KEY`) | Gateway | `workspace-gw-kimi-virtual-key` |
| API key | `/kimi-key/*`, `/kimi-key/v1/*` | none | Client | `workspace-gw-kimi-api-key` |

The credential slot clients call `api_key` carries a different string per mode:
OAuth access-token JWT, `vgw-*` virtual key, or `sk-...` Moonshot key.

### 2.2 Session keyed by issued-token hash

Sessions are stored under `sha256(access_token_as_issued)`. Refresh updates the
same record, so the client's stored credential keeps working indefinitely.

### 2.3 Explicit error handling

Missing header, `sk-` on `/kimi/*`, unknown session, and refresh failures all
return explicit 4xx/5xx; nothing proxies unauthenticated.

## 3. OAuth 2.0 Device Code Protocol

The gateway is a device-flow broker, not a transparent OAuth endpoint proxy.
The client receives an opaque gateway device-session code (`gw-<sha256>` of
request-unique material, minted by `oauth_broker.gateway_device_code`). The
gateway stores the upstream device code and user code, polls Kimi on the
client's behalf, normalizes the result, and keeps refresh tokens in OpenBao.

| Constant | Value |
|----------|-------|
| `CLIENT_ID` | `17e5f671-d194-4dfb-9706-5516cb48c098` |
| OAuth host | `https://auth.kimi.com` |
| Device authorization | `POST /api/oauth/device_authorization` |
| Token endpoint | `POST /api/oauth/token` |
| Grant types | `urn:ietf:params:oauth:grant-type:device_code`, `refresh_token` |
| Device code TTL | 900 s |
| Refresh threshold | 300 s (plugin default) |
| User-Agent | `Kimi CLI (Linux 6.17.0-35-generic x64)` (sent by `oauth_device.lua`) |

Pure RFC 8628: form-encoded POSTs, `authorization_pending`/`slow_down`
polling semantics, no PKCE, no redirect.

Sequence: `POST /kimi/auth/device?session=<id>` -> gateway calls Kimi and stores
upstream pending state -> user authorizes at `verification_uri` ->
`POST /kimi/auth/device/poll` with the opaque gateway `{ "device_code": ... }`
-> gateway polls Kimi -> token exchange -> session stored ->
`{ access_token, expires_in, account, session_id }`.

## 4. Plugin: oauth-auth (generic; Kimi config set)

`oauth-auth` is the single generic OAuth plugin shared by every OAuth
provider; Kimi is a per-route config set in `conf/apisix.yaml` (protocol
`rfc8628`). Plugin-wide defaults: priority 2560, `refresh_threshold` 300,
`ssl_verify` true, `user_agent` neutral. Kimi route config:

| Route conf property | Kimi value |
|---------------------|------------|
| `auth_base` | `/kimi/auth` |
| `oauth_host` | `https://auth.kimi.com` |
| `client_id` | `17e5f671-d194-4dfb-9706-5516cb48c098` |
| `device_authorize_path` | `/api/oauth/device_authorization` |
| `token_path` | `/api/oauth/token` |
| `user_agent` | `Kimi CLI (Linux 6.17.0-35-generic x64)` |
| `token_prefix` | `secret/data/gateway/kimi-tokens/` |
| `device_prefix` | `secret/data/gateway/kimi-device/` |
| `reject_key_prefix` / `reject_key_pointer` | `sk-` / `/kimi-key` |

### 4.2 access phase dispatch

| URI | Handler |
|-----|---------|
| `/kimi/auth/device` | `start_device_flow` |
| `/kimi/auth/device/poll` | `poll_device_flow` |
| other (proxy) | bearer validation, session load, refresh, header rewrite |

**start_device_flow:** request device authorization; store pending record
`{ device_code, session_id, expires_at, interval, created_at }` under
`sha256(device_code)`; return the verification payload. OpenBao write failure
-> 503 `cannot reach token store`; upstream failure -> 502.

**poll_device_flow:** read `device_code` from JSON body (400 if missing); load
pending record (400 `device session expired or invalid` if absent, 400
`device session expired` if past `expires_at`, record deleted); exchange; 202
`authorization_pending` while pending; 400 `device code expired` on expiry;
502 on exchange error. On success store the session record, delete the device
record, return `{ access_token, expires_in, account: { sub }, session_id }`.

**proxy:** extract bearer (401 `missing Authorization header`); reject `sk-`
(401 `API keys are not accepted on /kimi; use /kimi-key`); load session by
`sha256(bearer)` only (401 `session not found; run device flow first` on
miss); expiry prefers the JWT `exp` claim and falls back to the stored
`expires_at`, with unknown expiry failing closed into a refresh (shared
`oauth_session.ensure_fresh`); refresh and update the same session key
(401 `re-authenticate` + session delete on `invalid_grant`; 503
`token refresh failed` on transient error; 503 `cannot reach token store`
when the refreshed record cannot be persisted (the fresh token is never
issued unpersisted). OAuth HTTPS transport verifies TLS certificates
(`ssl_verify`, default true). Set:

- `Authorization: Bearer <fresh access_token>`
- `X-Gateway-Key-Id`: first 16 hex chars of the issued-token hash
- `X-Gateway-User-Id`: JWT `sub`
- `X-Gateway-Tenant-Id`: `session_id` or `default`
- `X-Gateway-Rate-Limit-RPM: 100`, `X-Gateway-Rate-Limit-Window: 60`
- `ctx.consumer.username = key_id`

No request-body rewrite.

### 4.3 Supporting modules

| Function | Module | Behavior |
|----------|--------|----------|
| `token_hash` | oauth_jwt | hex sha256 of the raw token |
| `decode_claims` | oauth_jwt | base64url payload decode, no signature verify |
| `expires_at` / `is_expiring` | oauth_jwt | `exp <= now + threshold` |
| `subject` | oauth_jwt | JWT `sub` claim |
| `request_device_authorization` | oauth_device | form POST, Kimi CLI UA |
| `poll_device_token` | oauth_device | maps pending/expired/success |
| `refresh_access_token` | oauth_device | `refresh_token` grant; surfaces `invalid_grant` |
| `store/load/delete_device` | oauth_store | OpenBao KVv2 under `kimi-device/` |
| `store_session` / `load_session_by_bearer` / `delete_session` | oauth_store | OpenBao KVv2 under `kimi-tokens/` |

## 5. OpenBao Storage

**Device pending**  -  `secret/data/gateway/kimi-device/{sha256(device_code)}`:
`{ device_code, upstream_device_code, user_code, session_id, expires_at,
interval, created_at }`. Deleted after
successful exchange or on expiry.

**Session**  -  `secret/data/gateway/kimi-tokens/{sha256(issued_access_token)}`:
`{ access_token, refresh_token, token_type, expires_in, expires_at, scope,
id_token, issued_access_token_hash, live_access_token_hash, sub, account_id,
session_id, updated_at }`. Refresh rewrites the record under the original issued-hash key.

Concurrent refreshes near expiry are tolerated via the short request window;
on refresh-token rotation a stale attempt returns `invalid_grant`, the session
is cleared, and the client re-authenticates (401).

## 6. Routes

All 6 routes upstream to `api.kimi.com:443` (HTTPS, `pass_host: node`) and
rewrite to `/coding/v1/*`:

| Route id | URI | Rewrite | Auth |
|----------|-----|---------|------|
| `relay-kimi` | `/kimi/*` | `^/kimi/(.*)` -> `/coding/v1/$1` | `oauth-auth` |
| `relay-kimi-v1` | `/kimi/v1/*` | `^/kimi/v1/(.*)` -> `/coding/v1/$1` | `oauth-auth` |
| `relay-kimi-federated` | `/kimi-federated/*` | `^/kimi-federated/(.*)` -> `/coding/v1/$1` | `key-resolver` (`KIMI_API_KEY`, `vgw-`) |
| `relay-kimi-federated-v1` | `/kimi-federated/v1/*` | `^/kimi-federated/v1/(.*)` -> `/coding/v1/$1` | `key-resolver` (same) |
| `relay-kimi-key` | `/kimi-key/*` | `^/kimi-key/(.*)` -> `/coding/v1/$1` | none |
| `relay-kimi-key-v1` | `/kimi-key/v1/*` | `^/kimi-key/v1/(.*)` -> `/coding/v1/$1` | none |

Common route plugins: `proxy-rewrite`, `key-meta`, `limit-count` (100/60s per
`http_x_key_hash`), `prometheus`, `request-id`, `http-logger`,
`proxy-buffering` (disabled), `redact`, `sse-usage`.

## 7. Error & Failure Model

| Condition | Status | Body |
|-----------|--------|------|
| Missing `device_code` | 400 | `oauth-auth: missing device_code` |
| Device record absent | 400 | `oauth-auth: device session expired or invalid` |
| Device record past expiry | 400 | `oauth-auth: device session expired` |
| Authorization still pending | 202 | `authorization_pending` |
| Device code expired upstream | 400 | `oauth-auth: device code expired` |
| Token exchange failure | 502 | `oauth-auth: token exchange failed: ...` |
| Missing Authorization header | 401 | `oauth-auth: missing Authorization header` |
| `sk-` bearer on `/kimi/*` | 401 | `oauth-auth: API keys are not accepted on /kimi/auth; use /kimi-key` |
| No session for bearer | 401 | `oauth-auth: session not found; run device flow first` |
| Refresh `invalid_grant` | 401 | `oauth-auth: re-authenticate` (session deleted) |
| Transient refresh failure | 503 | `oauth-auth: token refresh failed` |
| OpenBao down/unwritable | 503 | `oauth-auth: cannot reach token store` |

Security: HTTPS-only upstreams on `kimi.com`; tokens never logged (redact
plugin active on relay routes); device codes single-use with 900s TTL; the
client-held access token is a session secret treated like an API key.

## 8. Edge Cases & Decisions

- `session_id` is correlation/audit metadata only; never required post-handshake.
- Sessions resolve by issued-token hash only (2.2): refresh rewrites the same
  record, so the client-held credential resolves for the session lifetime.
  Any other bearer is an explicit 401.
- A successful refresh whose session record cannot be persisted terminates
  the request with 503; continuing with an unpersisted rotated refresh token
  would silently invalidate the client's credential on the next request.
- `/v1/usages` responses are informational and are not parsed for usage telemetry.

## 9. File Map

| File | Purpose | Key Changes |
|------|---------|-------------|
| `plugins/custom/oauth-auth.lua` | Plugin: device start/poll/proxy | priority 2560 |
| `plugins/custom/oauth_device.lua` | OAuth HTTP helpers | Kimi CLI User-Agent |
| `plugins/custom/oauth_jwt.lua` | JWT decode/expiry/hash | no signature verify |
| `plugins/custom/oauth_store.lua` | OpenBao KVv2 CRUD | device + session records |
| `conf/apisix.yaml` | 6 `relay-kimi*` routes | auth mode per route |
| `conf/providers/workspace-gw-kimi-*.yaml` | 3 OpenCode provider definitions | moonshotai model source |
| `tests/lua/test_oauth_jwt.lua` | JWT unit tests | decode/expiry/hash |

## 10. Implementation Status

| Component | Status | Evidence |
|-----------|--------|----------|
| oauth-auth plugin (device + proxy) | Implemented | plugins/custom/oauth-auth.lua |
| OAuth helpers / JWT / OpenBao modules | Implemented | oauth_device.lua, oauth_jwt.lua, oauth_store.lua |
| 6 relay routes | Implemented | conf/apisix.yaml |
| 3 provider YAMLs | Implemented | conf/providers/workspace-gw-kimi-*.yaml |
| JWT unit tests | Implemented | tests/lua/test_oauth_jwt.lua |
| Refresh race locking (`resty.lock`) | Not implemented | tolerated via short window; see REQ NFR notes |
