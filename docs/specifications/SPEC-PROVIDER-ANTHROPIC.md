# SPEC-PROVIDER-ANTHROPIC: Gateway API-Key Provider + Client-Side Subscription Path

**Date:** 2026-09-28
**Status:** Draft
**Type:** Specification
**Requirements:** [REQ-PROVIDER-ANTHROPIC](../requirements/REQ-PROVIDER-ANTHROPIC.md)
**Research:** [RES-ANTHROPIC-OAUTH](../research/RES-ANTHROPIC-OAUTH.md)

> Implementation design for the Anthropic client-authenticated surfaces: two
> provider-sync entries (an API-key entry on `/anthropic` and a coding-plan
> `passthrough` entry on `/anthropic-coding-plan`), plus the Claude Pro/Max
> subscription path. The coding-plan entry is addable via the OpenCode
> `/connect` TUI: its provider-sync block advertises a route-less
> `client_oauth` method, and the login script registers a thin per-provider
> wrapper over the maintained community auth plugin. The thin wrapper
> (`res/opencode-plugin/workspace-gateway-anthropic-plan.ts`) re-keys the
> plugin's OAuth hook to the gateway provider id and routes model traffic
> through the provider block's `options.baseURL`; the built-in `anthropic`
> provider remains an alternate path. All ride zero-auth passthrough routes.
> No Anthropic OAuth constant is implemented gateway-side and no committed
> file overrides the built-in provider.

---

**Cross-references:**
- [REQ-PROVIDER-ANTHROPIC](../requirements/REQ-PROVIDER-ANTHROPIC.md): requirements
- [RES-ANTHROPIC-OAUTH](../research/RES-ANTHROPIC-OAUTH.md): upstream protocol constants (client-side reference)
- [SPEC-PROVIDER-SYNC](SPEC-PROVIDER-SYNC.md): provider catalog and client-config service
- [`conf/apisix.yaml.j2`](../../conf/apisix.yaml.j2): relay route
- [`plugins/custom/provider-sync.lua`](../../plugins/custom/provider-sync.lua): OpenCode provider block rendering
- [`conf/providers/workspace-gw-anthropic-api-key.yaml`](../../conf/providers/workspace-gw-anthropic-api-key.yaml): API-key provider
- [`conf/providers/workspace-gw-anthropic-coding-plan-passthrough.yaml`](../../conf/providers/workspace-gw-anthropic-coding-plan-passthrough.yaml): coding-plan provider
- [`res/opencode-plugin/workspace-gateway-anthropic-plan.ts`](../../res/opencode-plugin/workspace-gateway-anthropic-plan.ts): thin client-side wrapper engine
- [`res/scripts/opencode-client-lib.sh`](../../res/scripts/opencode-client-lib.sh): login/plugin registration (`register_auth_plugin`)
- [`res/scripts/opencode-anthropic-max.sh`](../../res/scripts/opencode-anthropic-max.sh): community-plugin installer (built-in alternate)
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

### 2.2 `relay-anthropic-coding-plan`

A byte-identical twin of `relay-anthropic` on its own prefix, so
coding-plan (Claude Pro/Max subscription) traffic is attributable to a
separate provider. It shares the upstream, plugins, and no-auth contract;
only `id`, `uri`, and the rewrite regex differ.

```yaml
  - id: relay-anthropic-coding-plan
    uri: /anthropic-coding-plan/*
    upstream:
      type: roundrobin
      scheme: https
      pass_host: node
      nodes:
        "api.anthropic.com:443": 1
    plugins:
      proxy-rewrite:
        regex_uri: ["^/anthropic-coding-plan/(.*)", "/$1"]
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

`cost_calc.ROUTE_PROVIDERS` maps `relay-anthropic-coding-plan` to
`workspace-gw-anthropic-coding-plan-passthrough`.

### 2.3 No auth surface

There is no `/anthropic-device/*` route, no gateway verification page,
no provider-oauth engine, and no gateway OAuth route for Anthropic. Both
routes are pure passthrough.

## 3. Provider definitions

Two provider files share `npm: "@ai-sdk/anthropic"` and the models.dev
`anthropic` namespace, differing only in route, id, and auth mode.

### 3.1 API-key provider

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

### 3.2 Coding-plan passthrough provider

```yaml
---
id: workspace-gw-anthropic-coding-plan-passthrough
name: "Workspace GW (Anthropic Coding Plan Passthrough)"
provider: { id: anthropic-coding-plan, label: Anthropic Coding Plan }
route: "/anthropic-coding-plan/v1"
npm: "@ai-sdk/anthropic"
auth:
  type: passthrough
  methods:
    - id: anthropic-plan-client-oauth
      flow: client_oauth
      label: "Claude Pro/Max"
options: { headers: { X-Tenant-ID: default, X-User-ID: agent } }
context_limit_ceiling: 256000
model_source: { type: models_dev_provider, provider: anthropic }
pricing: { source: { type: models_dev, provider: anthropic }, missing_policy: unknown }
```

`passthrough` carries no gateway auth: no gateway auth route, no credential
store, no gateway OAuth engine. Its `methods` are **route-less** client-side
methods: `flow: client_oauth` tells the login script that OpenCode will
collect the credential itself and that the repository's thin wrapper engine
must be registered for this provider. The provider-sync `mode` contract is
unchanged (`passthrough` wins, so the id keeps its `-passthrough` suffix).
It is a catalog/attribution entry for clients that own their subscription
credential (Claude Code via the wrapper, or the OpenCode wrapper path).

## 4. Claude Pro/Max subscription path

The subscription path keeps auth client-side; the gateway is never involved
in authorization or token exchange. Two client paths exist:

### 4.1 Coding-plan provider via thin wrapper (supported path)

The `workspace-gw-anthropic-coding-plan-passthrough` entry is the
repository's TUI-addable path. Its provider-sync `/opencode` block carries
`auth_type: passthrough` plus a route-less `client_oauth` method (section
3.2); `make setup-providers` runs the login flow, which registers a
per-provider plugin wrapper for it (`register_auth_plugin` in
`res/scripts/opencode-client-lib.sh` dispatches on the method's `flow`).

The generated wrapper is a one-line OpenCode plugin at
`<opencode-config-dir>/plugin/wg-auth-<provider-id>.ts`:

```ts
import engine from "<repo>/res/opencode-plugin/workspace-gateway-anthropic-plan.ts";
export const WorkspaceGatewayAnthropicPlan = engine({
  provider: "workspace-gw-anthropic-coding-plan-passthrough",
  gateway: "http://localhost:9080/anthropic-coding-plan",
});
```

The engine wraps the maintained community plugin
`@ex-machina/opencode-anthropic-auth` (MIT, exact-pinned in
`res/opencode-plugin/package.json`; see
[RES-ANTHROPIC-OAUTH](../research/RES-ANTHROPIC-OAUTH.md) F4/F6). It makes
three adaptations, all client-side, none involving the gateway:

1. **Re-keys the hook.** The community plugin hardcodes
   `auth.provider = "anthropic"`; the engine rewrites the returned hook
   object's `provider` to the gateway id so OpenCode files the method under
   `workspace-gw-anthropic-coding-plan-passthrough`.
2. **Redirects refresh persistence.** On refresh the community plugin calls
   `client.auth.set({ path: { id: "anthropic" }, … })`; the engine proxies
   `input.client` so that write targets the gateway id instead, keeping the
   refreshed token under the same provider across restarts.
3. **Adds `beta=true` for the prefixed path.** The community plugin appends
   `?beta=true` only when the request `pathname` is exactly `/v1/messages`;
   the engine's `fetch` wrapper appends it for any path ending
   `/v1/messages` (the gateway route is prefixed).

The community plugin, unchanged, performs the PKCE exchange directly against
`claude.ai` / `platform.claude.com`, sets `Authorization: Bearer`,
`anthropic-beta: oauth-2025-04-20`, the Claude Code user-agent, and rewrites
the system prompt/tool names. Routing to the gateway comes from the
provider block's `options.baseURL`
(`<gateway>/anthropic-coding-plan/v1`, section 3.2), **not**
`ANTHROPIC_BASE_URL` (research F6: the plugin's env rewrite copies only
protocol/host and would drop the route prefix). The wrapper makes no gateway
call and holds no Anthropic OAuth constant.

The engine has a `bun:test` unit test
(`res/opencode-plugin/workspace-gateway-anthropic-plan.test.ts`) covering the
three adaptations; run via `make plugin-test`.

### 4.2 Built-in provider via community plugin (alternate path)

The built-in OpenCode `anthropic` provider may instead be used with the
community plugin directly, installed by
`res/scripts/opencode-anthropic-max.sh` (target `make setup-anthropic-max`):

- Pins the plugin spec (`@ex-machina/opencode-anthropic-auth@<version>`)
  into the OpenCode `plugin` array, idempotently, preserving unrelated
  entries and never touching the `anthropic` provider block.
- Refuses to run when a stale sibling config (`config.json`/`opencode.json`)
  exists, matching the single-file guard in the provider login script.
- Prints the runtime environment:
  `ANTHROPIC_BASE_URL=<gateway>/anthropic` and, for a self-signed gateway
  certificate, `ANTHROPIC_INSECURE=1`. Because the plugin rewrites only the
  origin, this path works only against a gateway that serves the Anthropic
  API at its root; it cannot target the path-prefixed coding-plan route
  (research F6). The supported path for the prefixed route is 4.1.

## 5. Provider-sync and login integration

`plugins/custom/provider-sync.lua` `build_opencode_block` now emits a
provider's declared `auth.methods` whenever the list is non-empty. A method
is emitted with `auth_route` only when it declares a `route`; a route-less
method (like `client_oauth`) is emitted as metadata for the client. The mode
contract (`plugins/custom/provider_sync_contract.lua`) is untouched:
`auth.type: passthrough` still yields mode `passthrough`, so the provider id
keeps its `-passthrough` suffix. The gateway `/opencode` blocks carry
`auth_type: api_key` (no methods) and `auth_type: passthrough` with one
route-less `client_oauth` method (research F6 / section 3.2).

Modeled on [SPEC-PROVIDER-SYNC](SPEC-PROVIDER-SYNC.md) FR-1.3/FR-5.7, the
`client_oauth` flow is the only route-less method flow today; the login
script (`res/scripts/opencode-client-lib.sh` `register_auth_plugin`)
dispatches on the first method's `flow`, selecting the Anthropic plan engine
for `client_oauth` and the gateway-exec engine otherwise. The built-in
alternate path remains wired entirely by `make setup-anthropic-max`.

## 6. Client wrapper

`res/scripts/claude-gw.sh` (REQ FR-5): sets
`ANTHROPIC_BASE_URL` (default
`http://localhost:9080/anthropic-coding-plan`, overridable via
`GW_BASE_URL`/`GW_ROUTE`), execs `claude`. No credential env is set or unset
by the wrapper. `GW_ROUTE=/anthropic` selects the API-key route instead.

## 7. Tests

| Test | What |
|------|------|
| `tests/config/test_provider_oauth_routes.sh` (sourced by `test_apisix_yaml.sh`) | `relay-anthropic` and `relay-anthropic-coding-plan` present, each with NO auth plugin and path-only rewrite; NO `relay-anthropic-device` route; the api-key and coding-plan YAMLs follow the id contract (`api_key` / `passthrough`); the coding-plan YAML declares exactly one `client_oauth` method with no `route`; the old `workspace-gw-anthropic-passthrough` id is gone |
| `tests/scripts/test_opencode_provider_login.sh` | `api_key` providers prompt and write auth.json; the coding-plan `client_oauth` block reports no gateway auth, registers its wrapper importing `workspace-gateway-anthropic-plan.ts`, bakes the provider id, and writes a config whose `baseURL` is the prefixed route; no regressions in the gateway-provider flow |
| `res/opencode-plugin/workspace-gateway-anthropic-plan.test.ts` (via `make plugin-test`) | the wrapper re-keys the hook provider, redirects `auth.set` to the gateway id, and adds `beta=true` for the prefixed messages path |
| `tests/scripts/test_opencode_anthropic_max.sh` | the installer adds the pinned community plugin spec idempotently, preserves unrelated plugin entries, and never writes `provider.anthropic` |
| e2e (local capture server) | passthrough relays headers/query verbatim (byte compare at the capture server); deferred until live credentials |

## 8. Rollout

1. Both routes + both provider yamls land behind the existing apisix
   render pipeline; `make sync-models` picks up anthropic models via
   provider sync.
2. `make setup-providers` installs the API-key and coding-plan providers.
3. API-key users run `make setup-providers REQUIRE_AUTH=1` once.
   Subscribers run `make setup-providers` (which registers the coding-plan
   wrapper), then `/connect` → `Anthropic Coding Plan` → `Claude Pro/Max`;
   model traffic routes via `options.baseURL`. The built-in alternate is
   `make setup-anthropic-max`, export `ANTHROPIC_BASE_URL`, then `/connect`
   → `Anthropic` → `Claude Pro/Max`.
4. The built-in `anthropic` provider is left untouched on disk. The
   historical `workspace-gw-anthropic-passthrough` id remains only as a
   recalc namespace equivalence for pre-rename rows; no provider file
   defines it.
5. Dashboards need no changes: usage lands in the standard
   `request_log`/`usage_log` shape via sse-usage like every provider, with
   coding-plan traffic separated by provider id.
