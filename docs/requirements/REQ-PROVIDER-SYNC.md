# REQ-PROVIDER-SYNC: Provider Sync & Client Config Service

**Date:** 2026-07-17
**Status:** Active
**Type:** Requirements
**Specification:** [SPEC-PROVIDER-SYNC](../specifications/SPEC-PROVIDER-SYNC.md)

> Mandates a gateway-managed provider catalog: the `provider-sync` APISIX plugin
> parses static provider YAMLs from `conf/providers/`, enriches them with model
> metadata and pricing from `models.dev` or gateway endpoints, caches the result
> in the `gateway-cache` shared dict, and exposes read-only `/gateway/providers*`
> endpoints for OpenCode clients. `provider-sync` is the SOLE writer of
> `pricing:*` keys. Explicitly excluded: storing client secrets, replacing
> `oauth-auth`, and editing routing/upstream config.

---

**Cross-references:**
- [SPEC-PROVIDER-SYNC](../specifications/SPEC-PROVIDER-SYNC.md): companion specification
- [`plugins/custom/provider-sync.lua`](../../plugins/custom/provider-sync.lua): plugin phases and HTTP endpoints
- [`plugins/custom/provider_sync_catalog.lua`](../../plugins/custom/provider_sync_catalog.lua): catalog load/enrich/sync logic
- [`plugins/custom/provider_sync_pricing.lua`](../../plugins/custom/provider_sync_pricing.lua): sole `pricing:*` writer
- [`conf/providers/`](../../conf/providers): 8 provider definition YAMLs
- [`res/scripts/opencode-provider-login.sh`](../../res/scripts/opencode-provider-login.sh): thin client login script
- [`res/opencode-plugin/workspace-gateway-auth.ts`](../../res/opencode-plugin/workspace-gateway-auth.ts): gateway-owned OpenCode auth plugin
- [`conf/apisix.yaml`](../../conf/apisix.yaml): `gateway-provider-sync` route

---

## 1. Purpose & Scope

### 1.1 Purpose

Make the gateway the single source of truth for provider and model metadata so
that OpenCode clients can fetch a ready-to-use provider block and so that
pricing is written exactly once, in one place.

### 1.2 Scope

**This document OWNS the requirements for:**
- Provider definition YAML schema contract (`conf/providers/*.yaml`)
- Catalog enrichment (models.dev provider, gateway/llamafile endpoints, static model metadata overlay)
- The `/gateway/providers*` HTTP endpoint family
- The `opencode-provider-login.sh` client login flow and safe config merge
- Endpoint security model and rate limiting
- Single-writer ownership of `pricing:*` cache keys

**This document DOES NOT:**
- Store or manage client credentials (client writes its own `auth.json`)
- Specify provider-specific OAuth flow internals (owned by the provider
  requirements; this client currently supports headless device authorization)
- Define cost computation (owned by `cost_calc`, a read-only consumer)

### 1.3 Terminology

| Term | Definition |
|------|------------|
| Provider | A configured upstream described by one YAML in `conf/providers/` plus its enriched model catalog |
| Enriched catalog | Provider definition + model metadata/pricing from `models.dev` or an endpoint |
| OpenCode provider block | JSON object inserted under `provider.<id>` in the OpenCode config |
| `pricing` | Declared pricing source, overrides, and missing-value policy |
| Provider-scoped pricing key | `pricing:<provider_id>:<canonical_model_id>`; provider identity is part of price identity |
| Pricing snapshot | Immutable generation containing the normalized provider rate cards |

## 2. Functional Requirements

### FR-1: Provider Definition Schema

| ID | Requirement |
|----|-------------|
| FR-1.1 | Each YAML in `conf/providers/` MUST contain exactly one provider document; the `id` field (not the filename) is authoritative. |
| FR-1.2 | Each provider MUST define: `id`, `name`, `route`, `npm`, `auth`, `options`, `model_source`. |
| FR-1.3 | `auth.type` MUST be one of `oauth`, `api_key`, `virtual_key`, `none`, `passthrough`; `oauth` requires `auth.plugin`. |
| FR-1.4 | `model_source.type` MUST be one of `models_dev_provider` (requires `provider`), `gateway` (requires `endpoint`), or `llamafile` (requires `endpoint`). |
| FR-1.5 | `pricing.source` MUST declare `models_dev` plus a provider id, or `unknown`; `pricing.overrides` MAY provide provider-specific model rates. |
| FR-1.6 | `context_limit_pct` (default 100) and `context_limit_ceiling` (default 0 = no cap) MAY scale exposed context limits. |
| FR-1.7 | `model_aliases` MAY map alias ids to real model ids; aliases MUST receive a deep copy of the target model entry. |
| FR-1.8 | `model_source.filter` (optional) MAY carry `include` / `exclude` lists of Lua patterns matched against normalized model ids. `exclude` patterns MUST drop matching ids; a non-empty `include` list MUST keep only matching ids. Applies to every `model_source.type`. |
| FR-1.9 | Files that fail to parse or lack an `id` MUST be skipped with a warning, never causing a 5xx. |

### FR-2: Sync & Enrichment

| ID | Requirement |
|----|-------------|
| FR-2.1 | Sync MUST acquire the `providers:lock` key (30s TTL) via `add`; a held lock MUST yield "sync already in progress" without error. |
| FR-2.2 | Sync MUST fetch `https://models.dev/api.json` with `User-Agent: Kimi CLI (Linux 6.17.0-35-generic x64)`; fetch failure MUST NOT abort sync (providers with endpoint sources still populate). |
| FR-2.3 | `gateway`/`llamafile` sources MUST query the configured endpoint (relative paths resolved against `http://localhost:9080`). Endpoint failure or zero ids MUST produce an empty model list plus an error log (explicit empty state; no static catalog substitution). `model_source.model_metadata` MAY overlay static metadata (name, limits, cost, capabilities) onto endpoint-reported ids only; it MUST NOT introduce ids the endpoint did not report. |
| FR-2.4 | Model ids MUST be normalized per `model_source.normalize` (`strip_prefix`, `lowercase`). |
| FR-2.5 | Sync MUST store `providers:raw`, `providers:enriched`, and `providers:ts` in `gateway-cache` with `stale_seconds` TTL (default 86400). |
| FR-2.6 | On plugin init, a warmup timer MUST run one sync with schema defaults when `warmup_on_init` is true. |
| FR-2.7 | Every model entry exposed to clients MUST carry a context limit whenever one is knowable: for `gateway`/`llamafile` sources, when neither `model_metadata` nor the endpoint supplies a limit, sync MUST borrow `limit.context`/`limit.output` from the models.dev catalog by exact normalized-id match (first models.dev provider in sorted-name order wins), then apply `context_limit_pct`/`context_limit_ceiling` as usual. Borrowing MUST NOT add models, ids, cost, or capability flags; models with no match anywhere remain without a limit. |

### FR-3: Pricing Single-Writer Ownership

| ID | Requirement |
|----|-------------|
| FR-3.1 | `provider-sync` (via `provider_sync_pricing.lua`) MUST be the sole writer of `pricing:*` keys in `gateway-cache`. |
| FR-3.2 | Pricing keys MUST be `pricing:<provider_id>:<canonical_model_id>` where canonicalization is `model_registry.canonical()`. |
| FR-3.3 | Provider pricing MUST be resolved independently; identical model ids under different providers MUST NOT collide. |
| FR-3.4 | The declared provider override wins per rate field, followed by models.dev, then discovered endpoint metadata; missing rates remain unknown. |
| FR-3.5 | Each pricing record MUST include provider identity, provenance, input/output/cache/reasoning rates, and `fetched_at`. |
| FR-3.6 | Sync MUST publish an immutable `pricing:snapshot:<generation>` and update `pricing:snapshot:active` only after the snapshot is written. |

### FR-4: HTTP Endpoints

| ID | Requirement |
|----|-------------|
| FR-4.1 | `GET /gateway/providers` MUST return a sorted JSON list of `{ id, name, auth_type }`. |
| FR-4.2 | `GET /gateway/providers/{id}` MUST return the full enriched provider, or 404 `{ "error": "provider not found" }`. |
| FR-4.3 | `GET /gateway/providers/{id}/opencode` MUST return an OpenCode provider block whose `options.baseURL` is built at request time from scheme/host/port plus the provider `route`. |
| FR-4.4 | The `/opencode` response MUST include `auth_type`, and MUST include `auth_route` only when `auth.type == "oauth"`; `auth_route` MUST be the first declared method's route (method metadata is authoritative, never reconstructed); OAuth responses MUST also include explicit `auth_methods` with method ids, flow types, and routes. |
| FR-4.5 | The gateway-owned OpenCode plugin at `res/opencode-plugin/workspace-gateway-auth.ts` MUST be loadable through OpenCode's standard `plugin` config array and MUST consume method-specific gateway routes. |
| FR-4.6 | `POST /gateway/providers/sync` MUST trigger a sync and return 200 with `{ ok, providers_loaded, models_enriched }`, 202 when a sync is already running, or 503 on failure. |
| FR-4.7 | All JSON responses MUST set `Content-Type: application/json`; unmatched URIs MUST return 404. |
| FR-4.8 | When the catalog is unavailable (cache empty and sync failed), endpoints MUST return 503 `{ "error": "provider catalog unavailable" }`. |

### FR-5: Client Login Flow

| ID | Requirement |
|----|-------------|
| FR-5.1 | The legacy client script MUST depend only on `bash`, `curl`, and `jq` (no Lua, Python, or Podman) and MUST NOT host an OAuth callback server. |
| FR-5.2 | The script MUST fetch `GET /gateway/providers/{id}/opencode` and branch on `auth_type`. |
| FR-5.3 | For the current headless OAuth method, the script MUST select the `device_authorization` method explicitly from `auth_methods` and run device authorization via that method's route (`POST <route>/device`, poll `POST <route>/device/poll`). Browser authorization-code/PKCE MUST be represented by a distinct flow method, not inferred from `auth_type: oauth`; a provider offering only browser flows MUST fail with a pointer to the gateway OpenCode auth plugin. |
| FR-5.4 | For `api_key`/`virtual_key`, the script MUST prompt for the key unless `--no-prompt` is set (then fail). |
| FR-5.5 | The script MUST insert or replace only the matching `provider.<id>` entry, preserving all other providers and top-level keys; JSONC input is rewritten as plain JSON. |
| FR-5.6 | The script MUST merge `{ "<id>": { "type": "api", "key": "<token>" } }` into the auth file and set its permissions to `600`. |
| FR-5.7 | For every OAuth provider (`auth_methods` non-empty), the script MUST register the gateway auth plugin in the OpenCode config `plugin` array. Because OpenCode collapses config entries that share one target file (last entry wins), each provider MUST get its own generated wrapper `~/.config/opencode/plugin/wg-auth-<provider-id>.ts` (imports `res/opencode-plugin/workspace-gateway-auth.ts`, bakes `{provider, gateway}` options) referenced as a plain string entry. Registration MUST be idempotent (rewrite wrapper, replace entry in place, no duplicates), MUST preserve unrelated plugin entries, and MUST remove the wrapper and entry (including legacy `file://` tuple entries) when a provider loses its OAuth methods. Providers without OAuth methods MUST NOT get an entry. |

### FR-6: Security Model

| ID | Requirement |
|----|-------------|
| FR-6.1 | `/gateway/providers*` endpoints MUST be read-only and return public metadata only (no credentials). |
| FR-6.2 | The route MUST apply `limit-count` rate limiting (60 req/min per `remote_addr`). |
| FR-6.3 | The service MUST remain auth-agnostic; operators MAY add `key-auth`/`forward-auth` to the route without plugin changes. |
| FR-6.4 | The plugin MUST NOT store client secrets; OAuth token custody remains with `oauth-auth`/OpenBao. |

## 3. Non-Functional Requirements

| ID | Requirement |
|----|-------------|
| NFR-1.1 | First request after startup SHOULD be served from a warmed cache (init-time sync). |
| NFR-1.2 | Sync MUST be idempotent and safe to trigger concurrently (lock-protected). |

## 4. Constraints

| ID | Constraint | Source |
|----|------------|--------|
| C-1 | `lyaml` YAML parsing with APISIX deps path prepended to `package.path`/`cpath` | provider_sync_catalog.lua |
| C-2 | `conf/providers/` mounted at `/usr/local/apisix/conf/providers` | res/docker |
| C-3 | Pricing key shape includes provider and canonical model identity; enforced by provider pricing tests | tests/lua/test_provider_pricing.lua |

## 5. Assumptions

| ID | Assumption |
|----|------------|
| A-1 | models.dev schema is `{ <provider>: { models: { <id>: {...} } } }`. |
| A-2 | Gateway/llamafile `/models` endpoints are OpenAI-compatible (`data[].id`). |

## 6. Open Questions

None. (Resolved: endpoints public + `limit-count` 60 RPM; `lyaml` available in
the APISIX image; provider dir mounted into the container.)

## 7. Verification Matrix

| # | Test | Maps to |
|---|------|---------|
| V1 | [`tests/lua/test_provider_sync.lua`](../../tests/lua/test_provider_sync.lua) | FR-2.x, FR-4.x |
| V2 | [`tests/scripts/test_opencode_provider_login.sh`](../../tests/scripts/test_opencode_provider_login.sh) | FR-5.x |
| V3 | [`tests/integration/test_provider_sync_client.sh`](../../tests/integration/test_provider_sync_client.sh) | FR-4.x, FR-5.x |
| V4 | [`tests/config/test_apisix_yaml.sh`](../../tests/config/test_apisix_yaml.sh), [`test_config_yaml.sh`](../../tests/config/test_config_yaml.sh) | FR-6.2, plugin registration |
| V5 | [`tests/config/test_model_registry.sh`](../../tests/config/test_model_registry.sh) | FR-3.x |

## 8. Implementation Status

| Item | Status | Evidence |
|------|--------|----------|
| FR-1.x provider YAMLs (8 files) | Implemented | conf/providers/*.yaml |
| FR-2.x sync & enrichment | Implemented | provider_sync_catalog.lua `M.sync` |
| FR-3.x pricing single writer | Implemented | provider_sync_pricing.lua |
| FR-4.x endpoints | Implemented | provider-sync.lua `plugin.access` |
| FR-5.x client script | Implemented | res/scripts/opencode-provider-login.sh (legacy device/API-key installer) |
| FR-2.7 models.dev limit borrowing | Implemented | provider_sync_catalog.lua `build_models_from_endpoint` |
| FR-5.7 plugin registration | Implemented | opencode-provider-login.sh `register_auth_plugin` |
| FR-4.5 native OAuth plugin | Implemented | res/opencode-plugin/workspace-gateway-auth.ts |
| FR-6.x security model | Implemented | conf/apisix.yaml `gateway-provider-sync` route (limit-count 60/60s) |
