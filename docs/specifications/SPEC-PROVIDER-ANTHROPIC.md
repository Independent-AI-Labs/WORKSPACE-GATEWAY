# SPEC-PROVIDER-ANTHROPIC: Gateway API-Key Provider + Client-Side Subscription Path

**Date:** 2026-09-28
**Status:** Draft
**Type:** Specification
**Requirements:** [REQ-PROVIDER-ANTHROPIC](../requirements/REQ-PROVIDER-ANTHROPIC.md)
**Research:** [RES-ANTHROPIC-OAUTH](../research/RES-ANTHROPIC-OAUTH.md)

> Implementation design for the two Anthropic client-authenticated paths: one
> provider-sync API-key entry, and the Claude Pro/Max subscription path on the
> built-in OpenCode `anthropic` provider via the maintained community auth
> plugin and a runtime `ANTHROPIC_BASE_URL`. Both ride the zero-auth
> `/anthropic` passthrough route. No Anthropic OAuth constant is implemented
> gateway-side and no committed file overrides the built-in provider.

---

**Cross-references:**
- [REQ-PROVIDER-ANTHROPIC](../requirements/REQ-PROVIDER-ANTHROPIC.md): requirements
- [RES-ANTHROPIC-OAUTH](../research/RES-ANTHROPIC-OAUTH.md): upstream protocol constants (client-side reference)
- [SPEC-PROVIDER-SYNC](SPEC-PROVIDER-SYNC.md): provider catalog and client-config service
- [`conf/apisix.yaml.j2`](../../conf/apisix.yaml.j2): relay route
- [`plugins/custom/provider-sync.lua`](../../plugins/custom/provider-sync.lua): OpenCode provider block rendering
- [`conf/providers/workspace-gw-anthropic-api-key.yaml`](../../conf/providers/workspace-gw-anthropic-api-key.yaml): API-key provider
- [`res/scripts/opencode-anthropic-max.sh`](../../res/scripts/opencode-anthropic-max.sh): community-plugin installer
- [`res/scripts/claude-gw.sh`](../../res/scripts/claude-gw.sh): client wrapper

---

## 1. Upstream constants (client-side only, not implemented here)

The Claude subscription protocol constants live in
[RES-ANTHROPIC-OAUTH](../research/RES-ANTHROPIC-OAUTH.md) section 2 and
are consumed by the **community** OpenCode auth plugin, not by the
gateway. They are recorded there for reference only; nothing in this
spec, and nothing in the gateway runtime, reads or reproduces them.

The gateway's only obligations for subscription traffic are byte
fidelity: relay `Authorization`, `anthropic-beta`, `anthropic-version`,
`anthropic-organization`, the query string, and the body unchanged.

## 2. Route (`conf/apisix.yaml.j2`)

### 2.1 `relay-anthropic`

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
        headers:
          set:
            accept-encoding: "identity"
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
  path and the plaintext-SSE `accept-encoding: identity` requirement
  shared with every SSE route. `pass_host: node` sends
  `Host: api.anthropic.com`; every other header, the query string, and
  the body are client-authored and untouched (REQ FR-2.1). This mirrors
  `relay-zai-key` minus any auth assumptions.
- Both an API key (`x-api-key: sk-ant-…`) and a subscription OAuth
  bearer (`Authorization: Bearer …` plus `anthropic-beta:
  oauth-2025-04-20`) relay verbatim; the route is indifferent to which
  the client sends.
- Clients append `/v1/*` paths themselves; the rewrite yields
  `/v1/messages` upstream. Query preservation is default proxy-rewrite
  behavior (only the path is replaced).

### 2.2 No second route

There is no `/anthropic-device/*` route, no gateway verification page,
no provider-oauth engine, and no gateway OAuth route for Anthropic.

## 3. Provider definition

The single provider file uses `provider.id: anthropic`, `route:
/anthropic/v1`, `npm: "@ai-sdk/anthropic"`, and anthropic models.dev
source/pricing, with `auth.type: api_key`.

```yaml
---
id: workspace-gw-anthropic-api-key
name: "Workspace GW (Anthropic API Key)"
provider: { id: anthropic, label: Anthropic }
route: "/anthropic/v1"
npm: "@ai-sdk/anthropic"
auth:
  type: api_key
options: { headers: { X-Tenant-ID: default, X-User-ID: agent } }
context_limit_ceiling: 256000
model_source: { type: models_dev_provider, provider: anthropic }
pricing: { source: { type: models_dev, provider: anthropic }, missing_policy: unknown }
```

`api_key` behaves like `workspace-gw-kimi-api-key`: no gateway-side auth
plugin, no auth route. The login script prompts for the user's Anthropic
key and writes it to the client auth store; OpenCode sends it as
`x-api-key` through the passthrough route.

## 4. Claude Pro/Max subscription path

The subscription path does **not** add a gateway provider entry. It uses
the built-in OpenCode `anthropic` provider, whose auth methods are
extended by the maintained community plugin
`@ex-machina/opencode-anthropic-auth` (MIT, actively maintained; see
[RES-ANTHROPIC-OAUTH](../research/RES-ANTHROPIC-OAUTH.md) F4). That plugin:

1. Registers a `Claude Pro/Max` OAuth method on provider id `anthropic`
   and performs the Anthropic PKCE exchange client-side, directly against
   `claude.ai` / `platform.claude.com`; the gateway is never involved in
   authorization or token exchange.
2. Returns a provider `fetch` wrapper that refreshes the token, sets
   `Authorization: Bearer`, `anthropic-beta: oauth-2025-04-20`, the
   Claude Code user-agent, and rewrites the system prompt/tool names so
   Anthropic accepts the request.
3. Rewrites the request origin from `ANTHROPIC_BASE_URL` when set, which
   is how model traffic is routed through the gateway.

`res/scripts/opencode-anthropic-max.sh` (target
`make setup-anthropic-max`) installs the path:

- Pins the plugin spec (`@ex-machina/opencode-anthropic-auth@<version>`)
  into the OpenCode `plugin` array, idempotently, preserving unrelated
  entries and never touching the `anthropic` provider block.
- Refuses to run when a stale sibling config (`config.json`/`opencode.json`)
  exists, matching the single-file guard in the provider login script.
- Prints the required runtime environment:
  `ANTHROPIC_BASE_URL=<gateway>/anthropic` and, for a self-signed gateway
  certificate, `ANTHROPIC_INSECURE=1`.

## 5. Provider-sync and login integration

No provider-sync or login changes are required for the subscription path:
the API-key provider is an ordinary `api_key` entry consumed by the
existing `make setup-providers` flow, and the subscription path is wired
entirely by `make setup-anthropic-max`. The gateway `/opencode` block for
`workspace-gw-anthropic-api-key` carries `auth_type: api_key` and no
`auth_route`.

## 6. Client wrapper

`res/scripts/claude-gw.sh` (REQ FR-5): sets
`ANTHROPIC_BASE_URL` (default `http://localhost:9080/anthropic`,
overridable via `GW_BASE_URL`/`GW_ROUTE`), execs `claude`. No credential
env is set or unset by the wrapper.

## 7. Tests

| Test | What |
|------|------|
| `tests/config/test_provider_oauth_routes.sh` (sourced by `test_apisix_yaml.sh`) | `relay-anthropic` present, has NO auth plugin and rewrites only the path; NO `relay-anthropic-device` route; the api-key YAML follows the id contract and declares `api_key`; the old passthrough YAML is gone |
| `tests/scripts/test_opencode_provider_login.sh` | `api_key` providers prompt and write auth.json; no regressions in the gateway-provider flow |
| `tests/scripts/test_opencode_anthropic_max.sh` | the installer adds the pinned community plugin spec idempotently, preserves unrelated plugin entries, and never writes `provider.anthropic` |
| e2e (local capture server) | passthrough relays headers/query verbatim (byte compare at the capture server); deferred until live credentials |

## 8. Rollout

1. Route + the api-key provider yaml land behind the existing apisix
   render pipeline; `make sync-models` picks up anthropic models via
   provider sync.
2. `make setup-providers` installs the API-key provider.
3. API-key users run `make setup-providers REQUIRE_AUTH=1` once;
   subscribers run `make setup-anthropic-max`, export `ANTHROPIC_BASE_URL`,
   then `/connect` → `Anthropic` → `Claude Pro/Max`.
4. The built-in `anthropic` provider is left untouched on disk; the former
   static fragment, its installer, and the `workspace-gw-anthropic-passthrough`
   provider are removed.
5. Dashboards need no changes: usage lands in the standard
   `request_log`/`usage_log` shape via sse-usage like every provider.
