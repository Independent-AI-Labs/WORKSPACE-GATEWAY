# Specification: Generic Provider Sync & Client Config Service

## Document Control

| Field | Value |
|-------|-------|
| Status | Implemented |
| Target Release | vNEXT (Kimi cost-calculation fix + client decoupling) |
| Owner | WORKSPACE-GATEWAY maintainers |
| Related Docs | `docs/PROVIDER-MOONSHOT-KIMI.md`, `docs/COST-CALC-LUA.md`, `docs/OPENCODE-INTEGRATION.md` |

---

## 1. Abstract

This specification defines a new gateway-managed service, implemented as a custom APISIX plugin named `provider-sync`, that:

1. Owns the provider catalog for the gateway.
2. Reads static provider definitions from `conf/providers/*.yaml`.
3. Enriches those definitions with live model metadata and pricing from `models.dev/api.json`.
4. Caches the enriched catalog in the shared memory (`gateway-cache`) used by the rest of the gateway.
5. Exposes read-only HTTP endpoints that return provider blocks formatted for OpenCode clients.

A thin client login script (`res/scripts/opencode-provider-login.sh`) consumes the endpoint, performs any provider-specific authentication (currently OAuth device flow for Kimi), and writes the provider block into the user's single OpenCode config file using a safe replace-or-insert strategy.

This design removes pricing/building logic from the client and from ad-hoc Lua helpers, and makes the gateway the single source of truth for provider and model metadata.

---

## 2. Context and Motivation

### 2.1 Current Problems

- The client login script (`opencode-kimi-login.sh`) currently pulls a Lua helper into the APISIX container via Podman to merge provider config and pricing. This is heavy for a client tool and requires a container runtime on the user's machine.
- Pricing logic is duplicated between the client-side Lua helper and the gateway-side `cost_calc.lua` module.
- The client is Kimi-specific and cannot be reused for other providers without copy-paste.
- The gateway's own provider YAML files (`conf/providers/*.yaml`) are not parsed or used by any runtime component; they are only documentation/templates.
- Outbound calls to Kimi's OAuth server (`auth.kimi.com`) do not present the official Kimi CLI user-agent, which may trigger fingerprinting or rate limits.

### 2.2 Desired Outcome

- One generic gateway service owns provider enrichment and exposes it to any authorized client.
- The client script is a thin shell wrapper: it calls the gateway, handles local file I/O, and writes auth tokens.
- The gateway looks like the official Kimi CLI when it talks to Kimi services.

---

## 3. Goals

1. **Gateway-managed catalog**: Provider YAMLs are parsed and enriched at runtime by a gateway plugin.
2. **Pricing synchronization**: Models and pricing are pulled from `models.dev/api.json` and cached with a configurable TTL.
3. **Generic client API**: Any OpenCode client can request a ready-to-use provider block by provider ID.
4. **Thin client**: The client script requires only `bash`, `curl`, and `jq`.
5. **Single-config merge**: The client safely inserts or replaces one provider entry inside the user's existing OpenCode config without destroying other providers.
6. **Kimi CLI emulation**: Gateway calls to Kimi OAuth use `User-Agent: Kimi CLI (Linux 6.17.0-35-generic x64)`.
7. **Reusability**: Future providers (e.g., `workspace-gw-xai`, `workspace-gw-anthropic`) can opt into the service by adding a YAML file and, if needed, a route; no changes to the core sync logic are required.

---

## 4. Non-Goals

- This service does **not** store client secrets (API keys, OAuth tokens). It returns public metadata only; the client writes credentials to its own `auth.json`.
- This service does **not** replace `kimi-auth`. It is a companion that runs on separate routes.
- This service does **not** rewrite gateway routing rules or upstream definitions. Those remain in `conf/apisix.yaml` and `conf/apisix.yaml.j2`.
- This service does not provide a UI or CLI for editing provider YAMLs. YAMLs are static configuration files.

---

## 5. Terminology

| Term | Meaning |
|------|---------|
| Provider | A configured upstream in `conf/providers/*.yaml` plus its enriched model catalog. |
| Provider definition | The static YAML file describing a provider. |
| Enriched catalog | Provider definition + model metadata/pricing from `models.dev`. |
| OpenCode provider block | The JSON object that goes under `provider.<provider_id>` in OpenCode config. |
| Client | The user's local machine running `opencode-provider-login.sh` to set up OpenCode. |
| Gateway | The APISIX instance running in the workspace stack. |

---

## 6. Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                        APISIX Gateway                        │
│  ┌─────────────────┐    ┌─────────────────────────────┐      │
│  │  provider-sync  │────│  gateway-cache (shared)    │      │
│  │  (custom plugin)│    │  - providers:raw           │      │
│  └─────────────────┘    │  - providers:enriched      │      │
│           │               │  - providers:ts              │      │
│           │               └─────────────────────────────┘      │
│           │                                                   │
│           ▼                                                   │
│  ┌─────────────────┐                                          │
│  │  models.dev     │ (periodic / on-demand fetch)             │
│  │  /api.json      │                                          │
│  └─────────────────┘                                          │
│           ▲                                                   │
│           │                                                   │
│  ┌─────────────────┐                                          │
│  │  cost_calc.lua  │ (reads enriched cache, no second fetch)  │
│  └─────────────────┘                                          │
└─────────────────────────────────────────────────────────────┘
           ▲
           │ GET /gateway/providers/{id}/opencode
┌──────────┴────────────────┐
│  opencode-provider-login.sh│
│  (bash + curl + jq)        │
└────────────────────────────┘
```

---

## 7. Provider Definition Schema (`conf/providers/*.yaml`)

Each YAML file MUST contain exactly one provider document. The filename is not authoritative; the `id` field is.

### 7.1 Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | OpenCode provider ID and gateway identifier. Example: `workspace-gw-kimi-oauth`. |
| `name` | string | Human-readable provider name. |
| `route` | string | Gateway route prefix for this provider. Example: `/kimi`. |
| `npm` | string | OpenCode SDK package. Example: `@ai-sdk/openai-compatible`. |
| `auth` | object | Authentication configuration (see §7.3). |
| `options` | object | SDK options passed through to the client (e.g., headers). The base URL is derived from `route`. |
| `model_source` | object | Where to fetch the model catalog (see §7.4). |

### 7.2 `auth` Object

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | yes | One of `oauth`, `api_key`, `virtual_key`, `none`, `passthrough`. |
| `plugin` | string | for `oauth` | Gateway auth plugin name. For Kimi OAuth this is `kimi-auth`. |
| `route` | string | for `oauth` | Gateway route used for authentication. Defaults to `/kimi/auth` for `kimi-auth`. |

### 7.3 `model_source` Object

| `type` | Required Fields | Behavior |
|--------|-----------------|----------|
| `models_dev_provider` | `provider` (string) | Pull models from `models.dev/api.json` under the named provider. Optional `normalize` controls `strip_prefix` and `lowercase`. |
| `gateway` | `endpoint` (string) | Query an OpenAI-compatible `/models` endpoint on the gateway. Optional `api_key` and `fallback` model list. |
| `llamafile` | `endpoint` (string) | Same as `gateway`; the endpoint typically points to a llamafile route. Optional `fallback` model list. |

### 7.4 Optional Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `cost_source` | string | `none` | models.dev provider id whose prices apply to this provider (e.g., `moonshotai`, `opencode`). During sync, models without a cost are filled from `models.dev[cost_source].models`; this is the ONLY pricing source - there is no cross-provider merge. |
| `context_limit_pct` | integer | 100 | Percentage of the upstream `limit.context` to expose to the client. |
| `context_limit_ceiling` | integer | 0 (no ceiling) | Maximum context tokens to expose; `0` means no cap. |
| `options.headers` | object | `{}` | Static headers the client should send to the gateway route. |

### 7.5 Example: `conf/providers/workspace-gw-kimi-oauth.yaml`

```yaml
id: workspace-gw-kimi-oauth
name: "Workspace GW (Kimi OAuth)"
route: "/kimi"
npm: "@ai-sdk/openai-compatible"
auth:
  type: oauth
  plugin: kimi-auth
options:
  headers:
    X-Tenant-ID: default
    X-User-ID: agent
model_source:
  type: models_dev_provider
  provider: moonshotai
  normalize:
    strip_prefix: "moonshotai/"
    lowercase: true
cost_source: moonshotai
```

### 7.6 Example: `conf/providers/workspace-gw-llamafile.yaml`

```yaml
id: workspace-gw-llamafile
name: "Workspace GW (llamafile)"
route: "/llamafile/v1"
npm: "@ai-sdk/openai-compatible"
auth:
  type: none
options:
  headers:
    X-Tenant-ID: default
    X-User-ID: agent
model_source:
  type: llamafile
  endpoint: "/llamafile/v1/models"
  fallback:
    - id: "/zip/MiniCPM5-1B-Q8_0.gguf"
      name: "MiniCPM5"
      limit:
        context: 131072
        output: 131072
      cost:
        input: 0
        output: 0
      tool_call: true
      reasoning: false
cost_source: none
```

---

## 8. Gateway Plugin: `provider-sync`

### 8.1 Module File

`plugins/custom/provider-sync.lua`

Loaded as `require("apisix.plugins.provider-sync")`.

### 8.2 Plugin Metadata

```lua
local plugin_name = "provider-sync"

local plugin = {
    version = 0.1,
    priority = 2570,   -- runs after kim-auth (2560) if both are on the same route
    name = plugin_name,
    schema = {
        type = "object",
        properties = {
            providers_dir = { type = "string", default = "/usr/local/apisix/conf/providers" },
            models_dev_url = { type = "string", default = "https://models.dev/api.json" },
            ttl_seconds = { type = "integer", default = 3600 },
            stale_seconds = { type = "integer", default = 86400 },
            sync_timeout = { type = "integer", default = 10000 },
            warmup_on_init = { type = "boolean", default = true },
        },
    },
}
```

### 8.3 Shared Cache Keys

| Key | Type | TTL | Description |
|-----|------|-----|-------------|
| `providers:raw` | JSON string | `stale_seconds` | Static provider definitions parsed from YAML. |
| `providers:enriched` | JSON string | `stale_seconds` | Provider definitions + enriched model metadata. |
| `providers:ts` | integer string | `stale_seconds` | Unix timestamp of last successful sync. |
| `providers:lock` | "1" | 30 | Fetch lock to prevent thundering herd. |

### 8.4 Phases

#### `init()`

APISIX calls `plugin.init()` during initialization. If `warmup_on_init` is true, the plugin spawns a `ngx.timer.at(0, ...)` that calls `M.sync()` once with the schema defaults. This warms the cache on startup so the first request is fast.

#### `access()`

Route by `ctx.var.uri`:

| URI Pattern | Action |
|-------------|--------|
| `GET /gateway/providers` | Return JSON list of `{ id, name, auth_type }`. `auth_type` is derived from `provider.auth.type`. |
| `GET /gateway/providers/([^/]+)` | Return full enriched provider object for the ID. |
| `GET /gateway/providers/([^/]+)/opencode` | Return OpenCode-formatted provider block with a dynamic `baseURL` built from the request's scheme/host and the provider's `route`. |
| `POST /gateway/providers/sync` | Trigger `M.sync()` and return summary. |
| otherwise | Return 404. |

All successful JSON responses include the `Content-Type: application/json` header.

### 8.5 Sync Logic (`M.sync()`)

1. Acquire the `providers:lock` using `add` with a short TTL. If the lock is held, return `"sync already in progress"` without error.
2. Read every `*.yaml` and `*.yml` file in `providers_dir` using `lyaml.load`.
3. Skip files that fail to parse or that lack an `id`; log a warning for each.
4. Fetch `models.dev/api.json` via `resty.http` with `User-Agent: Kimi CLI (Linux 6.17.0-35-generic x64)`. If the fetch fails, log a warning and continue with an empty catalog so that providers with gateway or llamafile `model_source` can still populate from their endpoints or fallback lists.
5. For each provider, use the `model_source.type` to decide how to build the model list:
   - `models_dev_provider`: merge the static definition with matching models from `models.dev` under `model_source.provider`.
   - `gateway` / `llamafile`: query `model_source.endpoint` (relative paths are resolved against `http://localhost:9080`) and merge with `model_source.fallback` if the endpoint fails or returns no IDs.
6. Normalize model IDs using `model_source.normalize` (`strip_prefix`, `lowercase`).
7. Apply `context_limit_pct` and `context_limit_ceiling` to each model's `limit.context`.
8. Serialize and store `providers:raw`, `providers:enriched`, and `providers:ts` in `gateway-cache`.
9. Populate `pricing:*` keys from the enriched model costs, keyed by CANONICAL model id (`model_registry.canonical()`), iterating providers in sorted order with first-writer-wins. `provider-sync` is the sole writer of these keys; `cost_calc` is read-only.
10. Release the lock.

### 8.6 Model Entry Transformation

For each model returned from the configured source:

```lua
{
    name = model.name or normalized_id,
    reasoning = model.reasoning or false,
    attachment = model.attachment or has_attachment(model.modalities),
    tool_call = model.tool_call ~= false,
    limit = {
        context = scale_limit(model.limit.context, context_limit_pct, context_limit_ceiling),
        output = model.limit.output or 8192,
    },
    cost = {
        input = model.cost.input or 0,
        output = model.cost.output or 0,
        cache_read = model.cost.cache_read,      -- optional
        cache_write = model.cost.cache_write,    -- optional
    }
}
```

`limit` is only included when the source model has a `limit` table. `cost` is only included when the source model has a `cost` table. `scale_limit` and `has_attachment` are copied from the current Lua helper behavior.

### 8.7 OpenCode Block Generation

The `/opencode` endpoint returns:

```json
{
  "provider_id": "workspace-gw-kimi-oauth",
  "provider": {
    "name": "Workspace GW (Kimi OAuth)",
    "npm": "@ai-sdk/openai-compatible",
    "options": {
      "baseURL": "http://localhost:9080/kimi",
      "headers": { "X-Tenant-ID": "default", "X-User-ID": "agent" }
    },
    "models": { "kimi-k2.7-code": { ... } }
  },
  "auth_type": "oauth",
  "auth_route": "/kimi/auth",
  "metadata": {}
}
```

The `baseURL` is constructed at request time from the incoming scheme/host and the provider's `route` (e.g. `route: "/kimi"` becomes `"http://localhost:9080/kimi"`). `options.headers` is copied verbatim from `provider.options.headers` when present. `auth_route` is set to `provider.route .. "/auth"` only when `provider.auth.type == "oauth"`; otherwise it is omitted.

The `provider` object is exactly the value that should be inserted under `provider["workspace-gw-kimi-oauth"]` in the OpenCode config.

---

## 9. API Endpoints

### 9.1 `GET /gateway/providers`

Request:

```bash
curl -s http://localhost:9080/gateway/providers
```

Response (200):

```json
[
  { "id": "workspace-gw-kimi-oauth", "name": "Workspace GW (Kimi OAuth)", "auth_type": "oauth" },
  { "id": "workspace-gw-kimi-private", "name": "Workspace GW (Kimi Federated)", "auth_type": "api_key" }
]
```

### 9.2 `GET /gateway/providers/{id}`

Response (200):

```json
{
  "id": "workspace-gw-kimi-oauth",
  "name": "Workspace GW (Kimi OAuth)",
  "models": { ... }
}
```

Response (404):

```json
{ "error": "provider not found" }
```

### 9.3 `GET /gateway/providers/{id}/opencode`

Response (200): see §8.7.

Response (404): same as §9.2.

### 9.4 `POST /gateway/providers/sync`

Request:

```bash
curl -s -X POST http://localhost:9080/gateway/providers/sync
```

Response (200):

```json
{
  "ok": true,
  "providers_loaded": 6,
  "models_enriched": 79
}
```

Response (202) if lock is already held:

```json
{ "ok": true, "status": "sync already in progress" }
```

Response (503) if fetch fails and no stale cache is usable:

```json
{ "error": "models.dev fetch failed", "details": "..." }
```

---

## 10. Client Script: `opencode-provider-login.sh`

### 10.1 Dependencies

- `bash` (4.0+)
- `curl`
- `jq`
- An OS browser opener (optional, for OAuth)

No Lua, no Python, no Podman.

### 10.2 CLI

```bash
bash res/scripts/opencode-provider-login.sh \
  --provider-id workspace-gw-kimi-oauth \
  --gateway http://localhost:9080 \
  --session alice \
  --config-file ~/.config/opencode/opencode.jsonc \
  --auth-file ~/.local/share/opencode/auth.json
```

### 10.3 Options

| Option | Default | Description |
|--------|---------|-------------|
| `--provider-id` | required | Provider ID to install. |
| `--gateway` | `http://localhost:9080` | Gateway base URL. |
| `--session` | `opencode-<timestamp>` | OAuth session label. |
| `--config-file` | `~/.config/opencode/opencode.jsonc` or `.json` | OpenCode config file. |
| `--auth-file` | `~/.local/share/opencode/auth.json` | OpenCode auth file. |
| `--user-agent` | `Kimi CLI (Linux 6.17.0-35-generic x64)` | User-Agent sent on all requests. |
| `--no-browser` | false | Do not attempt to open the browser. |
| `--no-prompt` | false | Do not prompt for API keys (fail instead). |
| `--help` | | Show usage. |

### 10.4 Flow

1. Validate dependencies (`curl`, `jq`).
2. Fetch `GET /gateway/providers/{provider_id}/opencode`.
   - Send `User-Agent: Kimi CLI (Linux 6.17.0-35-generic x64)`.
3. Inspect `auth_type` in the response.
4. If `auth_type == "oauth"`:
   - Use `auth_route` from the gateway response (e.g. `/kimi/auth`).
   - Start device flow via `POST {auth_route}/device?session=<session>`.
   - Open browser to `verification_uri_complete`.
   - Poll `POST {auth_route}/device/poll` until `access_token` is returned.
   - If the device flow returns an error, exit non-zero.
5. If `auth_type == "api_key"` or `"virtual_key"`:
   - Prompt the user for the key (unless `--no-prompt` is set).
6. Read the local OpenCode config file.
   - If the file is JSONC, strip `//` and `/* */` comments.
   - If the file does not exist, start with `{ "provider": {} }`.
7. Use `jq` to insert or replace the provider entry:

   ```bash
   jq --arg id "$PROVIDER_ID" --slurpfile block "$TMP/provider.json" \
      '.provider[$id] = $block[0].provider' "$CONFIG_FILE" > "$CONFIG_FILE.tmp"
   mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
   ```

8. Write the auth file:

   - For OAuth: `{ "<provider_id>": { "type": "api", "key": "<access_token>" } }` merged into existing auth file.
   - For API key: `{ "<provider_id>": { "type": "api", "key": "<user_key>" } }` merged into existing auth file.
9. Pretty-print both files and set `auth.json` permissions to `600`.
10. Print summary and example `opencode` command.

### 10.5 Safe Merge Rules

- Only the provider key matching `--provider-id` is modified.
- All other `provider.*` entries are preserved.
- Top-level keys other than `provider` are preserved.
- If the original config file was JSONC, the rewritten file is written as plain JSON (OpenCode accepts both).

---

## 11. Auth & Security Model

### 11.1 Endpoint Security

The `/gateway/providers*` endpoints are read-only and return only metadata and public pricing. They are designed to be **public** with `limit-count` rate limiting to prevent abuse.

Rationale:
- No credentials are returned.
- The model list is discoverable by hitting the provider anyway.
- Keeping the client stateless simplifies the login flow.

If an operator wants to restrict access, they can add a `key-auth` or `forward-auth` plugin to the route in `conf/apisix.yaml`; the `provider-sync` plugin itself remains auth-agnostic.

### 11.2 OAuth Flow Security

OAuth device flow remains the responsibility of the `kimi-auth` plugin on `/kimi/auth/*`. The client script does not handle OAuth tokens beyond receiving them from the gateway and storing them in the local `auth.json`.

---

## 12. User-Agent Emulation

### 12.1 Kimi CLI String

```
Kimi CLI (Linux 6.17.0-35-generic x64)
```

### 12.2 Where It Is Used

| Component | Endpoint / Target | Header |
|-----------|-------------------|--------|
| `kimi_device.lua` | `https://auth.kimi.com/api/oauth/*` | `User-Agent: Kimi CLI (Linux 6.17.0-35-generic x64)` |
| `provider-sync.lua` | `https://models.dev/api.json` | `User-Agent: Kimi CLI (Linux 6.17.0-35-generic x64)` |
| `opencode-provider-login.sh` | All gateway requests | `User-Agent: Kimi CLI (Linux 6.17.0-35-generic x64)` (default) |

### 12.3 Rationale

The gateway must present itself as the official Kimi CLI when talking to Kimi infrastructure to avoid being flagged as an unofficial or bot client. The client uses the same string for consistency and to simplify gateway logging/audit.

---

## 13. Integration with Existing Plugins

### 13.1 `cost_calc.lua`

`cost_calc.lua` is a read-only pricing consumer; `provider-sync` is the sole pricing writer.

Specific behavior:
- `provider-sync` writes per-model `pricing:*` entries into `gateway-cache` whenever it enriches providers, keyed by **canonical model id** from `conf/model-registry.yaml` (codegenned to `model_registry.lua`; CI fails on drift). Every alias of a model therefore resolves to the same price.
- Missing model costs are filled from the provider's declared `cost_source` (a models.dev provider id, e.g. `opencode`, `moonshotai`). There is no cross-provider cheapest-wins merge; the writer iterates providers in sorted order, first writer wins per canonical key.
- `cost_calc.get_pricing()` canonicalizes the requested model and reads `pricing:<canonical_id>`.
- If the price is missing **and** `providers:ts` is set, `cost_calc` returns a miss without triggering another fetch.
- If `providers:ts` is not set (provider-sync has not run yet), `cost_calc` calls `provider-sync.sync()` once. There is no direct models.dev fetch path in `cost_calc` (removed in v1.3).
- Historical rows with alias model strings are merged to canonical ids by `res/scripts/dedupe-model-history.sh`; the verbatim string is preserved in `usage_log.model_raw` / `billing_ledger.model_raw` (migration `000005_add_model_raw`).

This removes duplicate HTTP traffic to `models.dev` and ensures pricing is consistent between the gateway (`sse-usage`) and the client config.

### 13.2 `kimi-auth.lua` / `kimi_device.lua`

No functional changes except the User-Agent header in `kimi_device.lua`. The `/kimi/auth/device` and `/kimi/auth/device/poll` endpoints continue to work exactly as today.

### 13.3 `sse-usage.lua`

No direct changes, but it benefits from the unified cache: `cost_calc` will return the same pricing data used to build the client config.

---

## 14. Error Handling

### 14.1 Gateway Errors

| Scenario | HTTP Status | Body |
|----------|-------------|------|
| Provider ID not found | 404 | `{ "error": "provider not found" }` |
| Provider catalog unavailable (cache empty and sync failed) | 503 | `{ "error": "provider catalog unavailable", "details": "..." }` |
| Sync failed for a `POST /gateway/providers/sync` call | 503 | `{ "error": "sync failed", "details": "..." }` |
| Sync already in progress | 202 | `{ "ok": true, "status": "sync already in progress" }` |

YAML parse errors and missing `id` fields are logged as warnings; the offending file is skipped rather than causing a 500 response.

### 14.2 Client Errors

| Scenario | Action |
|----------|--------|
| Gateway unreachable | Exit with error, print gateway URL. |
| Provider ID not returned by gateway | Exit with error. |
| OAuth denied | Exit with error, print `error_description`. |
| Config file not writable | Exit with error, print path. |
| `jq` merge fails | Exit with error, print `jq` stderr. |

---

## 15. Testing Strategy

### 15.1 Unit / Plugin Tests

- `tests/lua/test_provider_sync.lua`: Runs inside the APISIX container via Podman.
  - Mounts a mock `conf/providers/` directory and a mock `models.dev/api.json`.
  - Calls the plugin functions directly with a fake `ngx` context.
  - Asserts that YAML files are parsed, models are enriched, and OpenCode output is correct.
  - Asserts that cache keys (`providers:raw`, `providers:enriched`, `providers:ts`) and the lock key are managed correctly.

### 15.2 Config Drift Tests

- `tests/config/test_config_yaml.sh`: assert `provider-sync` is present in `conf/config.yaml`.
- `tests/config/test_apisix_yaml.sh`: assert the `/gateway/providers*` route exists and has the correct plugins configured.
- `tests/config/test_apisix_yaml_render.sh`: assert the Jinja2 template renders the same routes.
- `tests/config/test_dockerfile.sh` and `tests/config/test_compose.sh`: assert the plugin and `conf/providers/` are mounted/copied into the APISIX image.
- `tests/config/test_cost_calc.sh`: assert `cost_calc` continues to work and does not duplicate fetches when the provider-sync catalog is available.

### 15.3 Client Script Tests

- `tests/scripts/test_opencode_provider_login.sh`:
  - Uses a Python mock server to serve the `/gateway/providers/{id}/opencode` response and device/poll endpoints.
  - Asserts that the script merges the provider block into an existing config without destroying other providers.
  - Asserts that `auth.json` is written correctly for OAuth and API-key providers.
  - Asserts that the User-Agent header is sent.

### 15.4 Integration Tests

`tests/integration/test_provider_sync_client.sh` runs against the ACTUAL running APISIX stack and real upstream endpoints. It does **not** use mocks.

- Triggers a real provider sync via `POST /gateway/providers/sync`.
- Verifies the live `/gateway/providers` list endpoint returns all configured providers.
- Verifies `/gateway/providers/{id}` and `/gateway/providers/{id}/opencode` for multiple providers.
- Runs `res/scripts/opencode-provider-login.sh` end-to-end and verifies the generated OpenCode config and auth files for:
  - `none` auth providers (`workspace-gw-llamafile`, `workspace-gw-kimi-own`).
  - `virtual_key` providers (`workspace-gw-private`) with piped API-key input.
- Verifies config merge preserves existing provider entries.
- Verifies JSONC config input is rewritten to valid JSON.
- Verifies invalid provider IDs fail gracefully.
- Initiates a real Kimi OAuth device flow via `/kimi/auth/device` and verifies the client script times out cleanly when the user does not authorize.
- Verifies `cost_calc` plugin still computes usage cost correctly after the refactor (via existing cost e2e tests).

---

## 16. Migration Plan (Completed)

### 16.1 Phase 1: Implement the gateway plugin ✅

1. Create `plugins/custom/provider-sync.lua`.
2. Add `provider-sync` to `conf/config.yaml`.
3. Add `/gateway/providers*` route to `conf/apisix.yaml` and `conf/apisix.yaml.j2`.
4. Add `tests/lua/test_provider_sync.lua` and update `tests/lua/run.sh`.
5. Verify `/gateway/providers/workspace-gw-kimi-oauth/opencode` returns a valid OpenCode block.

### 16.2 Phase 2: Refactor `cost_calc` ✅

1. Update `cost_calc.lua` to read from the `provider-sync` populated cache (`pricing:*` and `providers:ts`).
2. Keep the legacy `models.dev` fetch as a fallback when provider-sync is unavailable.
3. Run existing `tests/config/test_cost_calc.sh` and e2e usage-cost tests.

### 16.3 Phase 3: Rewrite the client script ✅

1. Write `res/scripts/opencode-provider-login.sh`.
2. Delete `res/scripts/opencode-kimi-login.sh` and `res/scripts/opencode-kimi-login.lua`.
3. Delete `res/scripts/sync-opencode-models.sh` and `res/scripts/sync-opencode-models.lua`.
4. Add `tests/scripts/test_opencode_provider_login.sh`, `tests/scripts/run.sh`, and wire them into `tests/run_all.sh`.

### 16.4 Phase 4: User-Agent emulation ✅

1. Update `plugins/custom/kimi_device.lua` to send the Kimi CLI user-agent.
2. Set the default user-agent in `opencode-provider-login.sh`.
3. Add assertions to the relevant tests.

### 16.5 Phase 5: Documentation and cleanup ✅

1. Update `docs/PROVIDER-MOONSHOT-KIMI.md`, `docs/OPENCODE-INTEGRATION.md`, and `docs/COST-CALC-LUA.md` to reflect the new architecture.
2. Remove any references to the old Lua/Podman helpers.
3. Update `AGENTS.md` if necessary.

---

## 17. Open Questions / Decisions

1. **Endpoint auth**: `/gateway/providers*` remain public with `limit-count` rate limiting (60 RPM per `remote_addr`). Operators may add `key-auth` or `forward-auth` to the route in `conf/apisix.yaml` if needed.
2. **YAML parser availability**: `lyaml` is available in the APISIX container; `provider-sync.lua` dynamically prepends the APISIX deps path to `package.path`/`package.cpath` before loading it.
3. **Provider YAML mount path**: `conf/providers/` is mounted to `/usr/local/apisix/conf/providers` in `res/docker/docker-compose.yml` and copied into the image by `res/docker/Dockerfile.apisix`.
4. **Rate limit values**: Public endpoints use `limit-count` with 60 requests per minute per `remote_addr`.

---

## 18. Appendix A: Example `/gateway/providers/workspace-gw-kimi-oauth/opencode` Response

```json
{
  "provider_id": "workspace-gw-kimi-oauth",
  "provider": {
    "name": "Workspace GW (Kimi OAuth)",
    "npm": "@ai-sdk/openai-compatible",
    "options": {
      "baseURL": "http://localhost:9080/kimi",
      "headers": { "X-Tenant-ID": "default", "X-User-ID": "agent" }
    },
    "models": {
      "kimi-k2.7-code": {
        "name": "Kimi K2.7 Code",
        "reasoning": true,
        "attachment": true,
        "tool_call": true,
        "limit": { "context": 262144, "output": 262144 },
        "cost": { "input": 0.95, "output": 4.0, "cache_read": 0.19 }
      }
    }
  },
  "auth_type": "oauth",
  "auth_route": "/kimi/auth",
  "metadata": {}
}
```

---

## 19. Appendix B: Files Added / Modified

### New Files

| File | Purpose |
|------|---------|
| `plugins/custom/provider-sync.lua` | Gateway plugin for provider sync and client config. |
| `res/scripts/opencode-provider-login.sh` | Generic thin client login script. |
| `tests/lua/test_provider_sync.lua` | Plugin unit tests. |
| `tests/lua/run.sh` | Lua test runner (updated to include provider-sync tests). |
| `tests/scripts/test_opencode_provider_login.sh` | Client script tests with a mock gateway. |
| `tests/integration/test_provider_sync_client.sh` | Real end-to-end integration test against the running gateway and upstream endpoints. |

### Modified Files

| File | Change |
|------|--------|
| `conf/config.yaml` | Add `provider-sync` to plugin list. |
| `conf/apisix.yaml` | Add `/gateway/providers*` route. |
| `conf/apisix.yaml.j2` | Same as above. |
| `res/docker/docker-compose.yml` | Mount `provider-sync.lua` and `conf/providers/`. |
| `res/docker/Dockerfile.apisix` | Copy `provider-sync.lua` and `conf/providers/`. |
| `plugins/custom/kimi_device.lua` | Send Kimi CLI user-agent to Kimi OAuth. |
| `plugins/custom/cost_calc.lua` | Read from shared provider cache populated by `provider-sync`; fall back to direct `models.dev` fetch only when provider-sync is unavailable. |
| `Makefile` | `sync-models` target now calls `POST /gateway/providers/sync`. |
| `res/ansible/dev.yml` | Sync task now triggers `POST /gateway/providers/sync`. |
| `tests/config/test_compose.sh` | Expect 16 APISIX volume mounts and assert provider-sync/providers mounts. |
| `tests/config/test_apisix_yaml.sh` | Expect 10 routes and assert provider-sync route. |
| `tests/config/test_config_yaml.sh` | Assert `provider-sync` is in plugin list. |
| `tests/config/test_dockerfile.sh` | Expect 12 custom plugins and assert provider-sync copy. |
| `res/scripts/opencode-provider-login.sh` | Add `--device-timeout` option for testability. |
| `tests/integration/run.sh` | Wire `test_provider_sync_client.sh` into the integration suite. |
| `tests/run_all.sh` | Includes the new `scripts` test stage. |
| `docs/PROVIDER-MOONSHOT-KIMI.md` | Document new flow. |
| `docs/OPENCODE-INTEGRATION.md` | Document new client setup. |
| `docs/COST-CALC-LUA.md` | Update cache integration description. |

### Deleted Files

| File | Reason |
|------|--------|
| `res/scripts/opencode-kimi-login.sh` | Replaced by the generic `opencode-provider-login.sh`. |
| `res/scripts/opencode-kimi-login.lua` | Logic moved to gateway plugin. |
| `res/scripts/sync-opencode-models.sh` | Replaced by `POST /gateway/providers/sync`. |
| `res/scripts/sync-opencode-models.lua` | Replaced by `POST /gateway/providers/sync`. |
| `tests/config/test_sync_opencode_models.sh` | Covered by the new provider-sync tests. |
