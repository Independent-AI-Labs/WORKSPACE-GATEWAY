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
> `kimi-auth`, and editing routing/upstream config.

---

**Cross-references:**
- [SPEC-PROVIDER-SYNC](../specifications/SPEC-PROVIDER-SYNC.md): companion specification
- [`plugins/custom/provider-sync.lua`](../../plugins/custom/provider-sync.lua): plugin phases and HTTP endpoints
- [`plugins/custom/provider_sync_catalog.lua`](../../plugins/custom/provider_sync_catalog.lua): catalog load/enrich/sync logic
- [`plugins/custom/provider_sync_pricing.lua`](../../plugins/custom/provider_sync_pricing.lua): sole `pricing:*` writer
- [`conf/providers/`](../../conf/providers): 6 provider definition YAMLs
- [`res/scripts/opencode-provider-login.sh`](../../res/scripts/opencode-provider-login.sh): thin client login script
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
- Catalog enrichment (models.dev provider, gateway/llamafile endpoints, backup models)
- The `/gateway/providers*` HTTP endpoint family
- The `opencode-provider-login.sh` client login flow and safe config merge
- Endpoint security model and rate limiting
- Single-writer ownership of `pricing:*` cache keys

**This document DOES NOT:**
- Store or manage client credentials (client writes its own `auth.json`)
- Specify OAuth device flow internals (owned by REQ-PROVIDER-KIMI)
- Define cost computation (owned by `cost_calc`, a read-only consumer)

### 1.3 Terminology

| Term | Definition |
|------|------------|
| Provider | A configured upstream described by one YAML in `conf/providers/` plus its enriched model catalog |
| Enriched catalog | Provider definition + model metadata/pricing from `models.dev` or an endpoint |
| OpenCode provider block | JSON object inserted under `provider.<id>` in the OpenCode config |
| `cost_source` | models.dev provider id whose prices fill missing model costs |
| Canonical model id | Model id normalized by `model_registry.canonical()`; the only key shape for `pricing:*` |

## 2. Functional Requirements

### FR-1: Provider Definition Schema

| ID | Requirement |
|----|-------------|
| FR-1.1 | Each YAML in `conf/providers/` MUST contain exactly one provider document; the `id` field (not the filename) is authoritative. |
| FR-1.2 | Each provider MUST define: `id`, `name`, `route`, `npm`, `auth`, `options`, `model_source`. |
| FR-1.3 | `auth.type` MUST be one of `oauth`, `api_key`, `virtual_key`, `none`, `passthrough`; `oauth` requires `auth.plugin`. |
| FR-1.4 | `model_source.type` MUST be one of `models_dev_provider` (requires `provider`), `gateway` (requires `endpoint`), or `llamafile` (requires `endpoint`). |
| FR-1.5 | `cost_source` (default `none`) MAY name a models.dev provider id whose prices fill models lacking a cost. |
| FR-1.6 | `context_limit_pct` (default 100) and `context_limit_ceiling` (default 0 = no cap) MAY scale exposed context limits. |
| FR-1.7 | `model_aliases` MAY map alias ids to real model ids; aliases MUST receive a deep copy of the target model entry. |
| FR-1.8 | Files that fail to parse or lack an `id` MUST be skipped with a warning, never causing a 5xx. |

### FR-2: Sync & Enrichment

| ID | Requirement |
|----|-------------|
| FR-2.1 | Sync MUST acquire the `providers:lock` key (30s TTL) via `add`; a held lock MUST yield "sync already in progress" without error. |
| FR-2.2 | Sync MUST fetch `https://models.dev/api.json` with `User-Agent: Kimi CLI (Linux 6.17.0-35-generic x64)`; fetch failure MUST NOT abort sync (providers with endpoint/backup sources still populate). |
| FR-2.3 | `gateway`/`llamafile` sources MUST query the configured endpoint (relative paths resolved against `http://localhost:9080`) and fall back to `backup_models` when the endpoint fails or returns no ids. |
| FR-2.4 | Model ids MUST be normalized per `model_source.normalize` (`strip_prefix`, `lowercase`). |
| FR-2.5 | Sync MUST store `providers:raw`, `providers:enriched`, and `providers:ts` in `gateway-cache` with `stale_seconds` TTL (default 86400). |
| FR-2.6 | On plugin init, a warmup timer MUST run one sync with schema defaults when `warmup_on_init` is true. |

### FR-3: Pricing Single-Writer Ownership

| ID | Requirement |
|----|-------------|
| FR-3.1 | `provider-sync` (via `provider_sync_pricing.lua`) MUST be the sole writer of `pricing:*` keys in `gateway-cache`. |
| FR-3.2 | Pricing keys MUST be `pricing:<canonical_model_id>` where canonicalization is `model_registry.canonical()`. |
| FR-3.3 | Providers MUST be iterated in sorted order with first-writer-wins per canonical key (deterministic cache content). |
| FR-3.4 | Missing model costs MUST be filled only from the provider's declared `cost_source`; there MUST be no cross-provider cheapest-wins merge. |
| FR-3.5 | Each pricing record MUST include `provider`, `input`, `output`, `cache_read`, `cache_write`, and `fetched_at`. |

### FR-4: HTTP Endpoints

| ID | Requirement |
|----|-------------|
| FR-4.1 | `GET /gateway/providers` MUST return a sorted JSON list of `{ id, name, auth_type }`. |
| FR-4.2 | `GET /gateway/providers/{id}` MUST return the full enriched provider, or 404 `{ "error": "provider not found" }`. |
| FR-4.3 | `GET /gateway/providers/{id}/opencode` MUST return an OpenCode provider block whose `options.baseURL` is built at request time from scheme/host/port plus the provider `route`. |
| FR-4.4 | The `/opencode` response MUST include `auth_type`, and MUST include `auth_route` (`<route>/auth`) only when `auth.type == "oauth"`. |
| FR-4.5 | `POST /gateway/providers/sync` MUST trigger a sync and return 200 with `{ ok, providers_loaded, models_enriched }`, 202 when a sync is already running, or 503 on failure. |
| FR-4.6 | All JSON responses MUST set `Content-Type: application/json`; unmatched URIs MUST return 404. |
| FR-4.7 | When the catalog is unavailable (cache empty and sync failed), endpoints MUST return 503 `{ "error": "provider catalog unavailable" }`. |

### FR-5: Client Login Flow

| ID | Requirement |
|----|-------------|
| FR-5.1 | The client script MUST depend only on `bash`, `curl`, and `jq` (no Lua, Python, or Podman). |
| FR-5.2 | The script MUST fetch `GET /gateway/providers/{id}/opencode` and branch on `auth_type`. |
| FR-5.3 | For `oauth`, the script MUST run the device flow via `auth_route` (`POST <auth_route>/device`, poll `POST <auth_route>/device/poll`). |
| FR-5.4 | For `api_key`/`virtual_key`, the script MUST prompt for the key unless `--no-prompt` is set (then fail). |
| FR-5.5 | The script MUST insert or replace only the matching `provider.<id>` entry, preserving all other providers and top-level keys; JSONC input is rewritten as plain JSON. |
| FR-5.6 | The script MUST merge `{ "<id>": { "type": "api", "key": "<token>" } }` into the auth file and set its permissions to `600`. |

### FR-6: Security Model

| ID | Requirement |
|----|-------------|
| FR-6.1 | `/gateway/providers*` endpoints MUST be read-only and return public metadata only (no credentials). |
| FR-6.2 | The route MUST apply `limit-count` rate limiting (60 req/min per `remote_addr`). |
| FR-6.3 | The service MUST remain auth-agnostic; operators MAY add `key-auth`/`forward-auth` to the route without plugin changes. |
| FR-6.4 | The plugin MUST NOT store client secrets; OAuth token custody remains with `kimi-auth`/OpenBao. |

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
| C-3 | Pricing key shape is canonical-id only; enforced by tests | tests/config/test_model_registry.sh |

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
| FR-1.x provider YAMLs (6 files) | Implemented | conf/providers/*.yaml |
| FR-2.x sync & enrichment | Implemented | provider_sync_catalog.lua `M.sync` |
| FR-3.x pricing single writer | Implemented | provider_sync_pricing.lua |
| FR-4.x endpoints | Implemented | provider-sync.lua `plugin.access` |
| FR-5.x client script | Implemented | res/scripts/opencode-provider-login.sh |
| FR-6.x security model | Implemented | conf/apisix.yaml `gateway-provider-sync` route (limit-count 60/60s) |
