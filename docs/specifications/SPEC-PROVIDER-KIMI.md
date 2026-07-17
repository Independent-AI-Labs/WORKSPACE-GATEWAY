# SPEC-PROVIDER-KIMI: Moonshot Kimi Provider Implementation

**Date:** 2026-07-17
**Status:** Active
**Type:** Specification
**Requirements:** [REQ-PROVIDER-KIMI](../requirements/REQ-PROVIDER-KIMI.md)

> Implements the Moonshot Kimi provider: RFC 8628 device-code OAuth via the
> `kimi-auth` plugin (priority 2560), OpenBao-backed session storage with
> transparent refresh, and 6 relay routes to `api.kimi.com/coding/v1` covering
> three access modes (OAuth, federated virtual key, own API key). Architecture
> context: [architecture/README.md](../architecture/README.md).

---

**Cross-references:**
- [REQ-PROVIDER-KIMI](../requirements/REQ-PROVIDER-KIMI.md): requirements
- [architecture/README.md](../architecture/README.md): gateway architecture hub
- [`plugins/custom/kimi-auth.lua`](../../plugins/custom/kimi-auth.lua): plugin phases
- [`plugins/custom/kimi_device.lua`](../../plugins/custom/kimi_device.lua): OAuth HTTP helpers (`request_device_authorization`, `poll_device_token`, `refresh_access_token`)
- [`plugins/custom/kimi_jwt.lua`](../../plugins/custom/kimi_jwt.lua): `decode_claims`, `expires_at`, `is_expiring`, `subject`, `token_hash`
- [`plugins/custom/kimi_tokens.lua`](../../plugins/custom/kimi_tokens.lua): OpenBao CRUD for device + session records
- [`conf/apisix.yaml`](../../conf/apisix.yaml): 6 `relay-kimi*` routes
- [`conf/providers/workspace-gw-kimi-oauth.yaml`](../../conf/providers/workspace-gw-kimi-oauth.yaml), [`-own`](../../conf/providers/workspace-gw-kimi-own.yaml), [`-private`](../../conf/providers/workspace-gw-kimi-private.yaml): provider definitions

---

## 1. Overview

```mermaid
graph TB
    U[User browser] --> AUTH[auth.kimi.com]
    C[Client] -->|Bearer access_token| KA[kimi-auth 2560]
    KA --> OB[(OpenBao kimi-tokens/ kimi-device/)]
    KA -->|refresh if near exp| AUTH
    KA --> PRW[proxy-rewrite /kimi/* -> /coding/v1/*]
    PRW --> API[api.kimi.com]
    C -->|vgw-*| KR[key-resolver] --> PRW2[/kimi-federated/* -> /coding/v1/*] --> API
    C -->|sk-...| PK[/kimi-key/* passthrough] --> API
```

No new containers: `kimi-auth` runs in the APISIX Lua worker; OpenBao stores
device and session records.

## 2. Architectural Principles

### 2.1 Three first-class modes, never mixed

| Mode | Route | Auth plugin | Secret custody | OpenCode id |
|------|-------|-------------|----------------|-------------|
| OAuth (managed) | `/kimi/*`, `/kimi/v1/*` | `kimi-auth` | Gateway (OpenBao holds refresh_token) | `workspace-gw-kimi-oauth` |
| Federated | `/kimi-federated/*`, `/kimi-federated/v1/*` | `key-resolver` (`KIMI_API_KEY`) | Gateway | `workspace-gw-kimi-private` |
| Own key | `/kimi-key/*`, `/kimi-key/v1/*` | none | Client | `workspace-gw-kimi-own` |

The credential slot clients call `api_key` carries a different string per mode:
OAuth access-token JWT, `vgw-*` virtual key, or `sk-...` Moonshot key.

### 2.2 Session keyed by issued-token hash

Sessions are stored under `sha256(access_token_as_issued)`. Refresh updates the
same record, so the client's stored credential keeps working indefinitely.

### 2.3 No silent fallbacks

Missing header, `sk-` on `/kimi/*`, unknown session, and refresh failures all
return explicit 4xx/5xx; nothing proxies unauthenticated.

## 3. OAuth 2.0 Device Code Protocol

| Constant | Value |
|----------|-------|
| `CLIENT_ID` | `17e5f671-d194-4dfb-9706-5516cb48c098` |
| OAuth host | `https://auth.kimi.com` |
| Device authorization | `POST /api/oauth/device_authorization` |
| Token endpoint | `POST /api/oauth/token` |
| Grant types | `urn:ietf:params:oauth:grant-type:device_code`, `refresh_token` |
| Device code TTL | 900 s |
| Refresh threshold | 300 s (plugin default) |
| User-Agent | `Kimi CLI (Linux 6.17.0-35-generic x64)` (sent by `kimi_device.lua`) |

Pure RFC 8628: form-encoded POSTs, `authorization_pending`/`slow_down`
polling semantics, no PKCE, no redirect.

Sequence: `POST /kimi/auth/device?session=<id>` -> gateway stores pending
record -> user authorizes at `verification_uri` ->
`POST /kimi/auth/device/poll` with `{ "device_code": ... }` -> token exchange
-> session stored -> `{ access_token, expires_in, account, session_id }`.

## 4. Plugin: kimi-auth

### 4.1 Manifest & schema

From `plugins/custom/kimi-auth.lua:9-51`: name `kimi-auth`, version 0.1,
priority 2560.

| Schema property | Default |
|-----------------|---------|
| `oauth_host` | `https://auth.kimi.com` |
| `api_host` | `https://api.kimi.com/coding` |
| `client_id` | `17e5f671-d194-4dfb-9706-5516cb48c098` |
| `openbao_addr` | `http://openbao:8200` |
| `openbao_token_env` | `OPENBAO_TOKEN` |
| `token_prefix` | `secret/data/gateway/kimi-tokens/` |
| `device_prefix` | `secret/data/gateway/kimi-device/` |
| `refresh_threshold` | 300 |

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
`sha256(bearer)` with JWT-`sub` fallback (401 `session not found; run device
flow first`); if the live token expires within `refresh_threshold`, refresh
and update the same session key (401 `re-authenticate` + session delete on
`invalid_grant`; 503 `token refresh failed` on transient error). Set:

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
| `token_hash` | kimi_jwt | hex sha256 of the raw token |
| `decode_claims` | kimi_jwt | base64url payload decode, no signature verify |
| `expires_at` / `is_expiring` | kimi_jwt | `exp <= now + threshold` |
| `subject` | kimi_jwt | JWT `sub` claim |
| `request_device_authorization` | kimi_device | form POST, Kimi CLI UA |
| `poll_device_token` | kimi_device | maps pending/expired/success |
| `refresh_access_token` | kimi_device | `refresh_token` grant; surfaces `invalid_grant` |
| `store/load/delete_device` | kimi_tokens | OpenBao KVv2 under `kimi-device/` |
| `store_session` / `load_session_by_bearer` / `delete_session` | kimi_tokens | OpenBao KVv2 under `kimi-tokens/` |

## 5. OpenBao Storage

**Device pending**  -  `secret/data/gateway/kimi-device/{sha256(device_code)}`:
`{ device_code, session_id, expires_at, interval, created_at }`. Deleted after
successful exchange or on expiry.

**Session**  -  `secret/data/gateway/kimi-tokens/{sha256(issued_access_token)}`:
`{ access_token, refresh_token, token_type, expires_in, expires_at, scope,
issued_access_token_hash, live_access_token_hash, sub, session_id,
updated_at }`. Refresh rewrites the record under the original issued-hash key.

Concurrent refreshes near expiry are tolerated via the short request window;
on refresh-token rotation a stale attempt returns `invalid_grant`, the session
is cleared, and the client re-authenticates (401).

## 6. Routes

All 6 routes upstream to `api.kimi.com:443` (HTTPS, `pass_host: node`) and
rewrite to `/coding/v1/*`:

| Route id | URI | Rewrite | Auth |
|----------|-----|---------|------|
| `relay-kimi` | `/kimi/*` | `^/kimi/(.*)` -> `/coding/v1/$1` | `kimi-auth` |
| `relay-kimi-v1` | `/kimi/v1/*` | `^/kimi/v1/(.*)` -> `/coding/v1/$1` | `kimi-auth` |
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
| Missing `device_code` | 400 | `kimi-auth: missing device_code` |
| Device record absent | 400 | `kimi-auth: device session expired or invalid` |
| Device record past expiry | 400 | `kimi-auth: device session expired` |
| Authorization still pending | 202 | `authorization_pending` |
| Device code expired upstream | 400 | `kimi-auth: device code expired` |
| Token exchange failure | 502 | `kimi-auth: token exchange failed: ...` |
| Missing Authorization header | 401 | `kimi-auth: missing Authorization header` |
| `sk-` bearer on `/kimi/*` | 401 | `kimi-auth: API keys are not accepted on /kimi; use /kimi-key` |
| No session for bearer | 401 | `kimi-auth: session not found; run device flow first` |
| Refresh `invalid_grant` | 401 | `kimi-auth: re-authenticate` (session deleted) |
| Transient refresh failure | 503 | `kimi-auth: token refresh failed` |
| OpenBao down/unwritable | 503 | `kimi-auth: cannot reach token store` |

Security: HTTPS-only upstreams on `kimi.com`; tokens never logged (redact
plugin active on relay routes); device codes single-use with 900s TTL; the
client-held access token is a session secret treated like an API key.

## 8. Edge Cases & Decisions

- `session_id` is correlation/audit metadata only; never required post-handshake.
- A rotated access token still resolves via the JWT-`sub` fallback lookup.
- If session storage fails after a successful refresh, the request proceeds
  with the fresh token (logged error) rather than failing.
- `/v1/usages` responses are informational and not parsed for usage telemetry.

## 9. File Map

| File | Purpose | Key Changes |
|------|---------|-------------|
| `plugins/custom/kimi-auth.lua` | Plugin: device start/poll/proxy | priority 2560 |
| `plugins/custom/kimi_device.lua` | OAuth HTTP helpers | Kimi CLI User-Agent |
| `plugins/custom/kimi_jwt.lua` | JWT decode/expiry/hash | no signature verify |
| `plugins/custom/kimi_tokens.lua` | OpenBao KVv2 CRUD | device + session records |
| `conf/apisix.yaml` | 6 `relay-kimi*` routes | auth mode per route |
| `conf/providers/workspace-gw-kimi-*.yaml` | 3 OpenCode provider definitions | moonshotai model source |
| `tests/lua/test_kimi_jwt.lua` | JWT unit tests | decode/expiry/hash |

## 10. Implementation Status

| Component | Status | Evidence |
|-----------|--------|----------|
| kimi-auth plugin (device + proxy) | Implemented | plugins/custom/kimi-auth.lua |
| OAuth helpers / JWT / OpenBao modules | Implemented | kimi_device.lua, kimi_jwt.lua, kimi_tokens.lua |
| 6 relay routes | Implemented | conf/apisix.yaml |
| 3 provider YAMLs | Implemented | conf/providers/workspace-gw-kimi-*.yaml |
| JWT unit tests | Implemented | tests/lua/test_kimi_jwt.lua |
| Refresh race locking (`resty.lock`) | Not implemented | tolerated via short window; see REQ NFR notes |
