# SPEC-PROVIDER-XAI: xAI Grok Provider Implementation

**Date:** 2026-07-17
**Status:** Draft
**Type:** Specification
**Requirements:** [REQ-PROVIDER-XAI](../requirements/REQ-PROVIDER-XAI.md)

> Intended design of the xAI Grok provider: a custom `xai-auth` APISIX plugin
> implementing OAuth 2.0 PKCE (browser paste + device code) against
> `auth.x.ai`, OpenBao-backed token storage with automatic refresh, and
> proxying `/grok/*` to `api.x.ai/v1/*`. Modeled on the implemented Kimi
> provider (SPEC-PROVIDER-KIMI). Protocol constants follow the official
> `xai-org/grok-build` client. Nothing described here exists in the codebase
> yet.

---

**Cross-references:**
- [REQ-PROVIDER-XAI](../requirements/REQ-PROVIDER-XAI.md): requirements contract
- SPEC-PROVIDER-KIMI / REQ-PROVIDER-KIMI: implemented analog ([`plugins/custom/kimi-auth.lua`](../../plugins/custom/kimi-auth.lua), [`plugins/custom/kimi_jwt.lua`](../../plugins/custom/kimi_jwt.lua), [`plugins/custom/kimi_tokens.lua`](../../plugins/custom/kimi_tokens.lua), [`plugins/custom/kimi_device.lua`](../../plugins/custom/kimi_device.lua))
- Legacy PROVIDER-XAI-GROK design (v1.1, absorbed)
- [`docs/architecture/README.md`](../architecture/README.md): architecture hub
- [`conf/apisix.yaml`](../../conf/apisix.yaml): route definitions (no `/grok` routes yet)

---

## 1. Overview

xAI Grok models are exposed through the gateway as an OpenAI-compatible
endpoint. OAuth is the primary credential path: the gateway brokers the PKCE
handshake, holds the `refresh_token` in OpenBao, and refreshes the upstream
Bearer proactively. Clients only ever see the OAuth `access_token` JWT, which
they paste into their SDK's credential slot (often named `api_key`  -  the
header field, not an xAI console key). A console `xai-...` key MAY be passed
through unchanged as a secondary side door.

## 2. Architectural Principles

### 2.1 OAuth access_token is the client credential

No `vgw-` virtual keys, no `key-resolver`, no `secret/data/gateway/keys/`
integration for Grok. Grok OAuth is a separate plugin and storage path.

### 2.2 Official protocol fidelity

Follow `xai-org/grok-build` (`crates/codegen/xai-grok-shell/src/auth/`), not
third-party folklore: standard PKCE exchange (no `code_challenge` echo), no
`plan=` parameter, ephemeral loopback ports (56121 only a preference),
`referrer=grok-build` default.

### 2.3 Proactive refresh, sticky client credential

Refresh when the JWT is within 300s of expiry; keep accepting the originally
issued access token string after rotation via hash aliasing.

### 2.4 No request-body rewrite

The plugin touches only `Authorization` and gateway meta headers.

## 3. System Diagram

```
 Admin/script         User browser                xAI
     |                    |                        |
     v                    v                        v
 /grok/auth/login --> 302 authorize URL -----> auth.x.ai (login)
 /grok/auth/complete <-- pasted callback URL ---
     |-- POST token exchange (standard PKCE) -> auth.x.ai/oauth2/token
     |-- store tokens -----------------------> OpenBao xai-tokens/{hash}
 /grok/auth/device[/poll] -------------------> RFC 8628 device flow

 Client (OpenCode / SDK / curl)
     |  Authorization: Bearer <access_token JWT>
     v
 APISIX: xai-auth (2560) -> refresh if near exp -> proxy-rewrite /grok/* -> /v1/*
     |--> key-meta (2530) --> redact --> sse-usage (2400)
     v
 api.x.ai:443
```

## 4. Plugin Manifest and Schema

| Property | Value |
|----------|-------|
| name | `xai-auth` |
| version | 0.2 |
| priority | 2560 (before `key-meta` 2530; after `key-resolver` 2555 if both present) |

| Schema property | Type | Default |
|-----------------|------|---------|
| `openbao_addr` | string | `http://openbao:8200` |
| `openbao_token_env` | string | `OPENBAO_TOKEN` |
| `client_id` | string | `b1a00492-073a-47ea-816f-4c329264a828` |
| `issuer` | string | `https://auth.x.ai` |
| `referrer` | string | `grok-build` |
| `scope` | string | `openid profile email offline_access grok-cli:access api:access` |
| `preferred_redirect_port` | integer | 56121 |
| `cache_ttl` | integer | 300 |
| `skew_seconds` | integer | 300 |
| `pkce_ttl` | integer | 300 |

## 5. Protocol Constants

| Constant | Value |
|----------|-------|
| `CLIENT_ID` | `b1a00492-073a-47ea-816f-4c329264a828` |
| `ISSUER` | `https://auth.x.ai` |
| `DISCOVERY_URL` | `https://auth.x.ai/.well-known/openid-configuration` |
| `DEFAULT_AUTH_ENDPOINT` | `https://auth.x.ai/oauth2/authorize` |
| `DEFAULT_TOKEN_ENDPOINT` | `https://auth.x.ai/oauth2/token` |
| `DEVICE_CODE_URL` | `https://auth.x.ai/oauth2/device/code` |
| `SCOPE` (min) | `openid profile email offline_access grok-cli:access api:access` |
| `REDIRECT_HOST` / path | `127.0.0.1` / `/callback` |
| `AUTHORIZE_REFERRER` | `grok-build` (overridable) |
| `REFRESH_SKEW` | 300 seconds |

Authorize URL parameters: `response_type=code`, `client_id`, `redirect_uri`,
`scope`, `code_challenge` (S256), `code_challenge_method=S256`, `state`,
`nonce`, `referrer`; optional `principal_type`/`principal_id`. No `plan=`.

## 6. Phase Handlers

| Phase | Path | Behavior |
|-------|------|----------|
| `init` |  -  | warm OIDC discovery into `ngx.shared.xai_cache` |
| `access` | `/grok/auth/login` | PKCE + store state (OpenBao, TTL 300s) + 302 or HTML with authorize URL |
| `access` | `/grok/auth/complete` | parse paste (full URL / fragment / bare code), exchange, persist, return access_token |
| `access` | `/grok/auth/device` | request device code, return `{verification_uri, user_code, device_code, interval, expires_in}` |
| `access` | `/grok/auth/device/poll` | poll until tokens; store; return `{access_token, expires_in, account}` |
| `access` | `/grok/*` (proxy) | resolve Bearer; refresh if near expiry; set upstream Authorization |

### 6.1 Token exchange (standard PKCE only)

Form fields: `grant_type=authorization_code`, `code`, `redirect_uri`,
`client_id`, `code_verifier`. Do NOT send `code_challenge` or
`code_challenge_method`.

### 6.2 Refresh

Form fields: `grant_type=refresh_token`, `client_id`, `refresh_token`
(optional `principal_type`/`principal_id`). If the response omits
`refresh_token`, keep the previous one. Serialize concurrent refreshes with
`resty.lock` on `token_hash`/`sub`; on rotation conflict clear the session
and return 401.

### 6.3 Proxy credential resolution

| Credential | Behavior |
|------------|----------|
| Starts with `xai-` | passthrough Bearer; set `X-Gateway-Key-Id` to key hash |
| JWT / other | OpenBao lookup by `sha256(credential)` or JWT `sub`; accept stale issued token as session handle; refresh within skew; send fresh token upstream |
| Missing / unknown | 401 with re-login hint |

Downstream headers: `X-Gateway-Key-Id`, `X-Gateway-User-Id`, optional
`X-Gateway-Tenant-Id`; `ctx.consumer.username` = key id.

### 6.4 Errors

| Condition | Status | Body |
|-----------|--------|------|
| Invalid paste / missing code | 400 | `xai-auth: invalid callback input` |
| PKCE state expired | 400 | `xai-auth: login session expired` |
| Token exchange failed | 502 | `xai-auth: token exchange failed: ...` |
| Not authenticated (proxy) | 401 | `xai-auth: not authenticated` |
| Refresh failed (invalid grant) | 401 | `xai-auth: re-authenticate` |
| Refresh 403 / entitlement | 403 | `xai-auth: subscription does not include API access` |
| OpenBao unreachable | 503 | `xai-auth: cannot reach token store` |

## 7. Supporting Modules

| File (planned) | Role |
|----------------|------|
| `plugins/custom/xai_pkce.lua` | verifier (32 random bytes, base64url), S256 challenge, hex state |
| `plugins/custom/xai_jwt.lua` | `decode_claims` (no signature verify), `is_expiring(token, skew)`, `token_hash` (hex sha256) |
| `plugins/custom/xai_oidc.lua` | discovery with HTTPS `*.x.ai` pinning, 1h cache in `xai_cache`, hardcoded fallbacks |
| `plugins/custom/xai_tokens.lua` | exchange, refresh, `normalize_tokens`, OpenBao CRUD, index aliases |

## 8. OpenBao Storage

### 8.1 PKCE pending  -  `secret/data/gateway/xai-pkce/{state}` (TTL 300s)

```json
{
  "verifier": "...", "challenge": "...", "session_id": "alice",
  "redirect_uri": "http://127.0.0.1:56121/callback",
  "nonce": "...", "created_at": "..."
}
```

### 8.2 OAuth session  -  `secret/data/gateway/xai-tokens/{token_hash}`

```json
{
  "tokens": { "access_token": "eyJ...", "refresh_token": "...",
              "id_token": "...", "token_type": "Bearer", "expires_in": 3600 },
  "issued_access_token_hash": "...",
  "live_access_token_hash": "...",
  "sub": "user-sub", "session_id": "alice",
  "account": { "email": "...", "user_id": "..." },
  "discovery": { "authorization_endpoint": "...", "token_endpoint": "..." },
  "client_id": "b1a00492-073a-47ea-816f-4c329264a828",
  "updated_at": "..."
}
```

Secondary indexes: `xai-tokens-by-sub/{sub}` and `xai-sessions/{session_id}`
point at the primary key. On refresh, update `tokens.access_token` and
`live_access_token_hash`; keep `issued_access_token_hash` so the user's
unchanged credential string still resolves.

## 9. Route Configuration (intended)

```yaml
routes:
  - id: xai-auth-login
    uri: /grok/auth/login
    plugins:
      xai-auth: { referrer: "grok-build" }

  - id: xai-auth-complete
    uri: /grok/auth/complete
    methods: [GET, POST]
    plugins:
      xai-auth: {}

  - id: xai-auth-device
    uris: [/grok/auth/device, /grok/auth/device/poll]
    methods: [POST, GET]
    plugins:
      xai-auth: {}

  - id: relay-grok
    uri: /grok/*
    plugins:
      xai-auth: {}
      proxy-rewrite:
        regex_uri: ["^/grok/(.*)", "/v1/$1"]
      key-meta: {}
      redact: {}
      sse-usage: {}
    upstream:
      type: roundrobin
      scheme: https
      nodes:
        "api.x.ai:443": 1
      pass_host: node
```

Shared dict: `lua_shared_dict xai_cache 5m` in `conf/config.yaml`
`nginx_config`. Env: `OPENBAO_TOKEN`, optional `XAI_CLIENT_ID`,
`XAI_OAUTH_REFERRER`.

## 10. Client Usage

- Login + paste: `GET /grok/auth/login?session=alice`, authenticate on real
  xAI pages, copy the `127.0.0.1` callback URL, POST it to
  `/grok/auth/complete?session=alice` -> `{access_token, expires_in, account}`.
- Device code (preferred remote): `POST /grok/auth/device?session=alice`,
  user opens `verification_uri` and enters `user_code`, then
  `POST /grok/auth/device/poll` -> access_token.
- Ongoing calls: `Authorization: Bearer <access_token>` against
  `http://gateway:9080/grok/chat/completions` (and `/grok/responses`,
  `/grok/models`). The gateway refreshes invisibly.

## 11. Edge Cases & Decisions

- **Stale client token after rotation:** accepted via `issued_access_token_hash` alias.
- **`/v1/responses`:** proxied but not usage-tracked by the current parser.
- **Refresh race:** `resty.lock`; rotation conflict clears session -> 401.
- **Out of scope v1:** `vgw-`/`key-resolver` integration, public redirect URI
  registration, `cli-chat-proxy.grok.com`, enterprise customer OIDC, external
  auth provider binary (can wrap complete later), `/v1/responses` usage parser.

## 12. File Map

| File | Purpose | Key Changes |
|------|---------|-------------|
| `plugins/custom/xai-auth.lua` (planned) | login/complete/device/proxy handlers | new file |
| `plugins/custom/xai_pkce.lua` (planned) | PKCE primitives | new file |
| `plugins/custom/xai_jwt.lua` (planned) | JWT claims + hash | new file |
| `plugins/custom/xai_oidc.lua` (planned) | discovery + pinning | new file |
| `plugins/custom/xai_tokens.lua` (planned) | exchange/refresh/OpenBao CRUD | new file |
| `conf/config.yaml` (planned edit) | register `xai-auth`, `xai_cache` dict | add entries |
| `conf/apisix.yaml` (planned edit) | 4 new `/grok` routes | add routes |
| `tests/lua/`, `tests/integration/` (planned) | unit + mock-endpoint integration | new tests |

## 13. Implementation Status

| Component | Status | Evidence |
|-----------|--------|----------|
| `plugins/custom/xai-auth.lua` | Not implemented | file does not exist; grep `xai` in `plugins/custom/`: no match |
| `xai_pkce.lua` / `xai_jwt.lua` / `xai_oidc.lua` / `xai_tokens.lua` | Not implemented | files do not exist in `plugins/custom/` |
| Plugin registration + `xai_cache` dict | Not implemented | `conf/config.yaml` contains no `xai-auth` or `xai_cache` |
| `/grok/*` routes | Not implemented | `conf/apisix.yaml` contains no `/grok` or `xai-auth` route |
| OpenBao `xai-*` paths | Not implemented | no `xai-pkce`/`xai-tokens` references anywhere in repo |
| Tests | Not implemented | no `tests/**` referencing xai/grok |
