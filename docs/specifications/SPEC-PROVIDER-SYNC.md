# SPEC-PROVIDER-SYNC: Provider Sync & Client Config Service Implementation

**Date:** 2026-07-17
**Status:** Active
**Type:** Specification
**Requirements:** [REQ-PROVIDER-SYNC](../requirements/REQ-PROVIDER-SYNC.md)

> Implements the gateway-managed provider catalog and OpenCode client config
> service. The `provider-sync` plugin (priority 2570) delegates catalog logic
> to `provider_sync_catalog.lua` and pricing writes to
> `provider_sync_pricing.lua` (split out for file-size limits). Key invariants:
> `provider-sync` is the sole writer of `pricing:*` keys (canonical model ids,
> sorted iteration, first-writer-wins); `cost_calc` is a read-only consumer;
> endpoints are read-only and auth-agnostic behind `limit-count`.

---

**Cross-references:**
- [REQ-PROVIDER-SYNC](../requirements/REQ-PROVIDER-SYNC.md): requirements
- [`plugins/custom/provider-sync.lua`](../../plugins/custom/provider-sync.lua): manifest, schema, `init`/`access`, OpenCode block builder
- [`plugins/custom/provider_sync_catalog.lua`](../../plugins/custom/provider_sync_catalog.lua): YAML load, models.dev fetch, enrichment, `sync`/`get_enriched`
- [`plugins/custom/provider_sync_pricing.lua`](../../plugins/custom/provider_sync_pricing.lua): `apply_cost_source`, `populate_pricing_cache`
- [`conf/providers/`](../../conf/providers): 6 provider YAMLs
- [`conf/apisix.yaml`](../../conf/apisix.yaml): `gateway-provider-sync` route (`/gateway/providers*`)
- [`res/scripts/opencode-provider-login.sh`](../../res/scripts/opencode-provider-login.sh): client login script

---

## 1. Overview

```
                 APISIX
  +---------------------------------------------------+
  | provider-sync (2570)                              |
  |   init: ngx.timer.at(0) -> sync() warmup          |
  |   access: route /gateway/providers*               |
  |        |                                          |
  |  provider_sync_catalog -- gateway-cache dict:     |
  |    providers:raw / providers:enriched /           |
  |    providers:ts / providers:lock                  |
  |        |                                          |
  |  provider_sync_pricing -- pricing:<canonical_id>  |
  +---------------------------------------------------+
       ^ reads conf/providers/*.yaml (lyaml)
       ^ fetches models.dev/api.json (Kimi CLI UA)
       ^ queries gateway/llamafile /models endpoints
       |
  GET /gateway/providers/{id}/opencode
       |
  opencode-provider-login.sh (bash + curl + jq)
```

## 2. Architectural Principles

### 2.1 Catalog owns its config

Schema defaults (`providers_dir`, `models_dev_url`, TTLs) are defined once as
constants in `provider_sync_catalog.lua`; the plugin schema references them, so
callers never hardcode paths.

### 2.2 Single pricing writer

`provider_sync_pricing.lua` is the only module that writes `pricing:*` keys;
`cost_calc.lua` exposes only `get_pricing`/`compute_cost`/`resolve_cost`
(read-only). Enforced by `tests/config/test_model_registry.sh`.

### 2.3 Canonical pricing keys

Keys are `pricing:<canonical_id>` via `model_registry.canonical()`, so every
alias of a model resolves to the same price and alias-shaped keys cannot
diverge. Providers are iterated in sorted order; first writer wins.

### 2.4 Fail-soft enrichment

A failed models.dev fetch logs a warning and sync continues with an empty
catalog so `gateway`/`llamafile` providers still populate from endpoints or
`backup_models`.

## 3. Provider Definition Schema (`conf/providers/*.yaml`)

One provider document per file; `id` is authoritative.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | yes | Provider id (e.g. `workspace-gw-kimi-oauth`) |
| `name` | string | yes | Display name |
| `route` | string | yes | Gateway route prefix (e.g. `/kimi`) |
| `npm` | string | yes | OpenCode SDK package |
| `auth.type` | enum | yes | `oauth` / `api_key` / `virtual_key` / `none` / `passthrough` |
| `auth.plugin` | string | for oauth | e.g. `kimi-auth` |
| `auth.api_key` | string | for virtual_key | e.g. `vgw-kimi-key` |
| `options.headers` | object | no | Static headers copied to the client block |
| `model_source.type` | enum | yes | `models_dev_provider` / `gateway` / `llamafile` |
| `model_source.provider` | string | for models_dev_provider | models.dev provider id |
| `model_source.normalize` | object | no | `strip_prefix`, `lowercase` |
| `model_source.endpoint` | string | for gateway/llamafile | `/models` endpoint; relative resolves to `http://localhost:9080` |
| `model_source.api_key` | string | no | Bearer for endpoint fetch |
| `model_source.backup_models` | list | no | Fallback model entries |
| `model_aliases` | map | no | alias id -> real model id (deep-copied entry) |
| `cost_source` | string | no (default `none`) | models.dev provider id used to fill missing costs |
| `context_limit_pct` | int | no (100) | Context scaling percentage |
| `context_limit_ceiling` | int | no (0 = none) | Context cap |

Deployed files (6): `workspace-gw-kimi-oauth` (oauth, moonshotai),
`workspace-gw-kimi-private` (virtual_key, moonshotai),
`workspace-gw-kimi-own` (none, moonshotai), `workspace-gw-private`
(virtual_key, opencode), `workspace-gw-own` (none, opencode),
`workspace-gw-llamafile` (none, `llamafile` source with `backup_models`,
`cost_source: none`). All three Kimi providers alias
`kimi-for-coding -> kimi-k2.7-code`.

## 4. Plugin Manifest & Schema

From `plugins/custom/provider-sync.lua:32-67`:

| Property | Value |
|----------|-------|
| name | `provider-sync` |
| version | 0.1 |
| priority | 2570 |

| Schema property | Default (catalog constant) |
|-----------------|----------------------------|
| `providers_dir` | `/usr/local/apisix/conf/providers` |
| `models_dev_url` | `https://models.dev/api.json` |
| `ttl_seconds` | 3600 |
| `stale_seconds` | 86400 |
| `sync_timeout` | 10000 (ms) |
| `warmup_on_init` | true |

## 5. Shared Cache Keys (`gateway-cache` dict)

| Key | TTL | Writer | Description |
|-----|-----|--------|-------------|
| `providers:raw` | `stale_seconds` | sync | Parsed YAML definitions |
| `providers:enriched` | `stale_seconds` | sync | Definitions + models |
| `providers:ts` | `stale_seconds` | sync | Last successful sync timestamp |
| `providers:lock` | 30s | sync | `add`-based fetch lock |
| `pricing:<canonical_id>` | 86400 | provider_sync_pricing | Per-model price record |

## 6. Sync Algorithm (`M.sync`)

1. `dict:add("providers:lock", "1", 30)`; if held, return
   `nil, "sync already in progress"`.
2. `load_providers`: list `*.yaml`/`*.yml` in `providers_dir`, parse with
   `lyaml` (deps path prepended to `package.path`/`cpath`), skip-and-warn on
   parse failure or missing `id`.
3. `fetch_models_dev`: GET `models_dev_url` with
   `User-Agent: Kimi CLI (Linux 6.17.0-35-generic x64)`; failure logs a warning
   and continues with an empty catalog.
4. Per provider: deep-copy the definition, then `enrich_provider_models`:
   - `models_dev_provider`: build entries from `models_dev[provider].models`.
   - `gateway`/`llamafile`: fetch endpoint (relative paths prefixed with
     `http://localhost:9080`, `User-Agent: WORKSPACE-GW/0.1`, optional Bearer);
     on failure or empty id list use `backup_models`.
   - Unknown source type: warn, empty model list.
5. Apply `model_aliases`: copy the target entry under each alias id.
6. `pricing.apply_cost_source(provider, models, models_dev)`: for each model
   without a cost, copy the cost from
   `models_dev[cost_source].models[<id or canonical(id)>]`.
7. Store `providers:raw` / `providers:enriched` / `providers:ts`; delete lock.
8. `pricing.populate_pricing_cache(enriched)`: sorted provider iteration,
   first-writer-wins `pricing:<canonical_id>` records
   `{ provider, input, output, cache_read, cache_write, fetched_at }`.
9. Return `{ providers_loaded, models_enriched }`.

`get_enriched` returns the cached catalog; on a total miss (no `providers:ts`)
it triggers one sync; if `ts` exists but the enriched blob is gone it returns
`nil, "cache miss"`.

### 6.1 Model entry transformation

`build_model_entry` normalizes the id (`strip_prefix`, `lowercase`) and emits:

```lua
{
  name = model.name or normalized_id,
  reasoning = model.reasoning or false,
  attachment = model.attachment or has_attachment(model.modalities),
  tool_call = model.tool_call ~= false,
  limit = { context = scale_limit(ctx, pct, ceiling),
            output = model.limit.output or 8192 },   -- only if source has limit
  cost = { input, output, cache_read?, cache_write? }, -- only if source has cost
}
```

`has_attachment` is true when `modalities.input` contains `image` or `video`.
`scale_limit` floors `context * pct / 100` and clamps to `ceiling` when > 0.

## 7. HTTP Endpoints (`plugin.access`)

| URI | Response |
|-----|----------|
| `POST /gateway/providers/sync` | 200 `{ ok, providers_loaded, models_enriched }`; 202 `{ ok, status: "sync already in progress" }`; 503 `{ error: "sync failed", details }` |
| `GET /gateway/providers` | 200 sorted `[{ id, name, auth_type }]` |
| `GET /gateway/providers/{id}` | 200 enriched provider; 404 `{ error: "provider not found" }` |
| `GET /gateway/providers/{id}/opencode` | 200 OpenCode block; 404 as above |
| other | 404 `{ error: "not found" }` |

Catalog unavailable (no cache and sync failed): 503
`{ error: "provider catalog unavailable", details }` before any GET is served.

### 7.1 OpenCode block

```json
{
  "provider_id": "workspace-gw-kimi-oauth",
  "provider": {
    "name": "...", "npm": "@ai-sdk/openai-compatible",
    "options": { "baseURL": "<scheme>://<host>[:port]<route>",
                 "headers": { "...": "..." } },
    "models": { ... }
  },
  "auth_type": "oauth",
  "auth_route": "/kimi/auth",
  "metadata": {}
}
```

`baseURL` derives from the incoming request's scheme/host/port (port omitted
for 80/443). `auth_route` is `<route>/auth` only for `auth.type == "oauth"`.

## 8. Route Configuration

`conf/apisix.yaml` route `gateway-provider-sync`: uri `/gateway/providers*`,
plugins `provider-sync`, `limit-count` (60 per 60s per `remote_addr`,
`rejected_code: 429`), `prometheus`, `request-id`. Upstream is a loopback
node; the plugin generates the response in `access`.

## 9. Client Script (`opencode-provider-login.sh`)

Options: `--provider-id` (required), `--gateway` (default
`http://localhost:9080`), `--session`, `--config-file`, `--auth-file`,
`--user-agent` (default Kimi CLI string), `--no-browser`, `--no-prompt`,
`--device-timeout` (default 900s).

Flow: validate `curl`/`jq` and gateway URL -> fetch the `/opencode` block ->
branch on `auth_type` (oauth: device flow via `auth_route`; api_key/
virtual_key: prompt unless `--no-prompt`) -> strip JSONC comments -> `jq` merge
`.provider[$id] = $block.provider` -> merge
`{ "<id>": { "type": "api", "key": "<token>" } }` into `auth.json` with
mode `600` -> print summary.

Safe-merge rules: only the matching provider key is touched; other providers
and top-level keys are preserved; JSONC input is rewritten as plain JSON.

## 10. Integration with cost_calc and model-registry

- `cost_calc.get_pricing()` canonicalizes the requested model and reads
  `pricing:<canonical_id>`; it never fetches models.dev directly.
- On a pricing miss with `providers:ts` unset, `cost_calc` triggers one
  `provider-sync.sync()`; with `ts` set it returns a plain miss.
- `conf/model-registry.yaml` is the single source of truth for canonical ids
  (codegenned into `model_registry.lua` by
  `res/scripts/gen-model-registry.sh`; CI fails on drift).
- Historical alias rows are merged by `res/scripts/dedupe-model-history.sh`;
  verbatim strings are preserved in `*_log.model_raw` (migration 000005).

## 11. Edge Cases & Decisions

- YAML files without `id` or with parse errors are skipped with warnings.
- `providers:lock` uses `add`, so concurrent syncs collapse to one.
- Endpoint fetch uses `ssl_verify = false` for in-cluster HTTP calls.
- `get_enriched` does not re-sync on a stale-but-present `providers:ts`;
  refresh is via `POST /sync`, warmup, or TTL-driven consumers.

## 12. File Map

| File | Purpose | Key Changes |
|------|---------|-------------|
| `plugins/custom/provider-sync.lua` | Plugin: schema, init warmup, HTTP routing | thin wrapper over catalog |
| `plugins/custom/provider_sync_catalog.lua` | YAML load, enrichment, sync, cache | owns defaults and cache keys |
| `plugins/custom/provider_sync_pricing.lua` | `pricing:*` writer + cost_source fill | split from catalog; sole writer |
| `conf/providers/*.yaml` | 6 provider definitions | incl. `model_aliases`, `backup_models` |
| `conf/apisix.yaml` | `gateway-provider-sync` route | limit-count 60 RPM |
| `res/scripts/opencode-provider-login.sh` | Client login | bash+curl+jq only |
| `tests/lua/test_provider_sync.lua` | Unit tests | mock ngx + fixtures |
| `tests/scripts/test_opencode_provider_login.sh` | Script tests | mock gateway |
| `tests/integration/test_provider_sync_client.sh` | Live end-to-end | real stack |

## 13. Implementation Status

| Component | Status | Evidence |
|-----------|--------|----------|
| Plugin + endpoints | Implemented | plugins/custom/provider-sync.lua |
| Catalog sync/enrichment | Implemented | provider_sync_catalog.lua |
| Pricing writer split | Implemented | provider_sync_pricing.lua |
| Provider YAMLs (6) | Implemented | conf/providers/ |
| Route + rate limit | Implemented | conf/apisix.yaml `gateway-provider-sync` |
| Client script | Implemented | res/scripts/opencode-provider-login.sh |
| Tests (unit/script/integration) | Implemented | tests/lua, tests/scripts, tests/integration |
