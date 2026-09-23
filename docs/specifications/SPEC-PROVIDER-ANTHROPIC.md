# SPEC-PROVIDER-ANTHROPIC: Anthropic Passthrough + Device Facade

**Date:** 2026-09-19
**Status:** Draft
**Type:** Specification
**Requirements:** [REQ-PROVIDER-ANTHROPIC](../requirements/REQ-PROVIDER-ANTHROPIC.md)
**Research:** [RES-ANTHROPIC-OAUTH](../research/RES-ANTHROPIC-OAUTH.md)

> Implementation design for the two Anthropic providers: a zero-auth
> passthrough route and a custodial device facade over Anthropic's
> browser PKCE grant. All protocol constants come from
> RES-ANTHROPIC-OAUTH section 2 and are repeated here exactly once.

---

**Cross-references:**
- [REQ-PROVIDER-ANTHROPIC](../requirements/REQ-PROVIDER-ANTHROPIC.md): requirements
- [SPEC-PROVIDER-KIMI](SPEC-PROVIDER-KIMI.md): device facade pattern this follows
- [`plugins/custom/provider-oauth.lua`](../../plugins/custom/provider-oauth.lua), [`oauth_device.lua`](../../plugins/custom/oauth_device.lua), [`oauth_session.lua`](../../plugins/custom/oauth_session.lua), [`oauth_store.lua`](../../plugins/custom/oauth_store.lua)
- [`conf/apisix.yaml.j2`](../../conf/apisix.yaml.j2)
- [`res/scripts/claude-gw.sh`](../../res/scripts/claude-gw.sh)

---

## 1. Verified upstream constants (single source)

```yaml
anthropic_oauth:
  client_id: "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  authorize_path: "/oauth/authorize"          # host: claude.ai (older console.anthropic.com)
  token_host: "platform.claude.com"           # authorize host and token host DIFFER
  token_path: "/v1/oauth/token"
  manual_redirect_uri: "https://platform.claude.com/oauth/code/callback"
  scopes: "user:inference user:profile"
  request_encoding: json                       # token + refresh bodies are JSON
  pkce: S256_state_is_verifier                 # state == code_verifier
  code_param: true
  callback_payload: "CODE#STATE"
```

## 2. Routes (`conf/apisix.yaml.j2`)

### 2.1 `relay-anthropic` (passthrough, provider A)

```yaml
  - id: relay-anthropic
    uri: /anthropic/*
    upstream:
      type: roundrobin
      scheme: https
      pass_host: node
      nodes:
        "api.anthropic.com:443": 1
    plugins:
      proxy-rewrite:
        regex_uri: ["^/anthropic/(.*)", "/$1"]
      key-meta: {}
      limit-count: { count: 100, time_window: 60, rejected_code: 429,
                     key_type: var, key: http_x_key_hash, policy: local }
      prometheus: { prefer_name: true }
      request-id: { header_name: X-Request-Id, include_in_response: true }
      http-logger: { uri: "http://vector:8080/ingest", method: POST,
                     content_type: "application/json", batch_max_size: 1,
                     include_req_body: true, include_resp_body: true,
                     max_req_body_bytes: 262144, max_resp_body_bytes: 1048576 }
      proxy-buffering: { disable: true }
      redact: { patterns_file: "/etc/apisix/redact-patterns.json" }
      sse-usage: { clickhouse_addr: "http://clickhouse:8123" }
```

Notes:
- No `provider-oauth`, no `key-resolver`, no header rewrites besides the
  path. `pass_host: node` sends `Host: api.anthropic.com`; every other
  header, the query string, and the body are client-authored and
  untouched (REQ FR-2.1). This mirrors `relay-zai-key` minus any auth
  assumptions.
- Claude Code hits `/anthropic/v1/messages?beta=true`; the rewrite
  yields `/v1/messages?beta=true` upstream. Query preservation is
  default proxy-rewrite behavior (only the path is replaced).

### 2.2 `relay-anthropic-device` (custodial, provider B)

Same upstream/rewrite/observability as 2.1, plus `provider-oauth` before
`key-meta`:

```yaml
      provider-oauth:
        auth_base: /anthropic-device/auth
        protocol: anthropic            # new engine (section 3)
        oauth_host: "https://claude.ai"
        client_id: "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        token_host: "https://platform.claude.com"   # schema addition
        authorize_path: /oauth/authorize
        authorize_params: { code: "true" }
        token_path: /v1/oauth/token
        request_encoding: json
        scopes: "user:inference user:profile"
        token_prefix: "secret/data/gateway/anthropic-tokens/"
        device_prefix: "secret/data/gateway/anthropic-device/"
        reject_key_prefix: "sk-ant-"
        reject_key_pointer: /anthropic
        inject_headers:                # schema addition (section 3.4)
          anthropic-beta: "oauth-2025-04-20"
        beta_query_path: "/v1/messages"
```

## 3. Plugin work

### 3.1 `provider-oauth` schema additions

| Field | Purpose |
|-------|---------|
| `token_host` | Token endpoint origin when it differs from `oauth_host` (Anthropic: authorize on claude.ai, token on platform.claude.com) |
| `inject_headers` | Static upstream header injection on relay (the OAuth beta header) |
| `beta_query_path` | Path suffix that gets `?beta=true` appended upstream when absent |

### 3.2 New protocol engine `anthropic` (in `oauth_device.lua` alongside `rfc8628`/`chatgpt_device`)

Browser PKCE flow, GW-driven:

1. `POST {auth_base}/browser` generates a 43-char base64url verifier,
   S256 challenge, and `state = verifier`; stores the pending record
   (OpenBao `device_prefix` keyed by sha256 of a gateway nonce) and
   returns the authorize URL built from section 1 constants plus
   `code=true`, `redirect_uri = manual_redirect_uri`.
2. The user completes login at claude.ai on any device; the manual
   callback page shows `CODE#STATE`; the user pastes it into the GW
   verification page (`GET {auth_base}/verify?user_code=...`), which
   POSTs `{code_state}` to `POST {auth_base}/browser/callback`.
3. The engine splits `CODE#STATE` on `#`, verifies the state half
   equals the stored verifier, and exchanges the code at
   `token_host + token_path` with a JSON body
   `{grant_type, code, state, client_id, redirect_uri, code_verifier}`.
4. Refresh: JSON body `{grant_type: "refresh_token", refresh_token,
   client_id}`; a response without a new `refresh_token` keeps the old
   one (REQ FR-3.5).

### 3.3 Device facade (engine composes with existing endpoints)

- `POST {auth_base}/device`: gateway mints `user_code` (8 chars,
  `XXXX-XXXX`) + `device_code` (random 256-bit), stores pending state,
  returns `{user_code, verification_uri: "{public_origin}{auth_base}/verify?user_code=...",
  interval: 5, expires_in: 900}`.
- `POST {auth_base}/device/poll`: on approval completes the session
  write and returns the gateway session bearer per the existing
  provider-oauth session contract (`authorization_pending`/`slow_down`
  202 semantics, `expired_token`/`access_denied` terminal).
- The verification page: static HTML shell + one fetch call; it starts
  the browser flow (3.2 step 1), collects the pasted `CODE#STATE`, and
  submits it. No third-party assets; served by the `oauth_verify.lua`
  module wired into `provider-oauth` (gated by `verify_page`). The pending
  device record is also indexed under `uc-{user_code}` so the page can
  find it; the index is deleted on completion and expiry.

### 3.4 Relay phase (both providers' contract)

On `/anthropic-device/*` data requests: validate the client bearer
against `token_prefix` sessions, refresh if inside the threshold,
overwrite `Authorization: Bearer <live access token>`, apply
`fixed_upstream_headers` (the `anthropic-beta: oauth-2025-04-20`
header), append `?beta=true` when the path ends with
`beta_query_path` and the query is absent, then proxy.
`/anthropic/*` never enters this phase (no provider-oauth on the route).

## 4. Provider definitions

```yaml
---
id: workspace-gw-anthropic-passthrough
name: "Workspace GW (Anthropic Passthrough)"
provider: { id: anthropic, label: Anthropic }
route: "/anthropic"
npm: "@anthropic-ai/sdk"
auth: { type: passthrough }
options: { headers: { X-Tenant-ID: default, X-User-ID: agent } }
model_source: { type: models_dev_provider, provider: anthropic }
pricing: { source: { type: models_dev, provider: anthropic }, missing_policy: unknown }
---
id: workspace-gw-anthropic-device-oauth
name: "Workspace GW (Anthropic Device OAuth)"
provider: { id: anthropic, label: Anthropic }
route: "/anthropic-device"
npm: "@anthropic-ai/sdk"
auth:
  type: oauth
  plugin: provider-oauth
  methods:
    - id: anthropic-device-oauth
      flow: device_authorization
      route: /anthropic-device/auth
options: { headers: { X-Tenant-ID: default, X-User-ID: agent } }
model_source: { type: models_dev_provider, provider: anthropic }
pricing: { source: { type: models_dev, provider: anthropic }, missing_policy: unknown }
```

`auth.type: passthrough` is a new enum value in the provider-sync
contract: no credentials are written to client auth stores, and the
opencode login tool must skip auth for it (config block only, like
`--all` without `--require-auth`).

## 5. Client wrapper

`res/scripts/claude-gw.sh` (already on disk per REQ FR-4): sets
`ANTHROPIC_BASE_URL=https://gw.workspaceguardrails.com/anthropic`
(defaults overridable via `GW_BASE_URL`/`GW_ROUTE`), execs `claude`.
No credential env is set or unset by the wrapper.

## 6. Tests

| Test | What |
|------|------|
| `tests/config/test_provider_oauth_routes.sh` (sourced by `test_apisix_yaml.sh`) | relay-anthropic + relay-anthropic-device present; passthrough route has NO auth plugin and rewrites only the path; device route carries provider-oauth with the section 1 constants; both provider YAMLs follow the id contract |
| `tests/lua/test_oauth_device.lua` (anthropic engine block) | minted codes make no upstream call; authorize URL quirks (state == verifier, `code=true`, scopes); JSON token/refresh bodies on `token_host`; refresh-without-rotation keeps old token; poll pending |
| `tests/lua/test_provider_oauth.lua` (facade block) | device start + `uc-` index; verify page served; verify start via query `user_code`; `CODE#STATE` split + single-use state; approval marks the record; poll short-circuit hands out the stored bearer without rewriting the session; `?beta=true` appended only on the messages path |
| e2e (local capture server) | passthrough relays headers/query verbatim (byte compare at the capture server); device end-to-end against real claude.ai; deferred until live credentials |

## 7. Rollout

1. Routes + engine + provider yamls land behind the existing apisix
   render pipeline; `make gw-sync-model-registry` picks up anthropic
   models via provider sync.
2. Wrapper is usable immediately for provider A (clients `/login`
   themselves).
3. Device facade enabled after e2e; OpenBao prefixes provisioned empty.
4. Dashboards need no changes: usage lands in the standard
   `request_log`/`usage_log` shape via sse-usage like every provider.
