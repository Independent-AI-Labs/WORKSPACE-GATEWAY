# Custom Plugins

**Date:** 2026-07-17

Extract-testable-core pattern: `*_lib.lua` (pure logic) + `*.lua` (APISIX
adapter). Six plugins are registered in `conf/config.yaml`:
`key-resolver`, `key-meta`, `kimi-auth`, `provider-sync`, `sse-usage`,
`redact`. All sources live in [`plugins/custom/`](../../plugins/custom/).

## key-resolver

**File:** `key-resolver.lua` (235 lines)
**Priority:** 2555 | **Phase:** access | **Routes:** federated (opencode + kimi)

- `vgw-*`: OpenBao lookup, cache in `key_cache` shared dict, inject upstream
  `Authorization`
- Non-`vgw-`: passthrough bearer token
- Sets `X-Gateway-Key-Id`, `X-Gateway-Tenant-Id`, `X-Gateway-User-Id`

| Error | Status |
|-------|--------|
| Missing Authorization | 401 |
| Key not found / revoked | 401 |
| OpenBao unreachable | 503 |
| key_cache missing | 500 |

OpenBao path: `secret/data/gateway/keys/<token>`

## key-meta

**File:** `key-meta.lua` (61 lines)
**Priority:** 2530 | **Phases:** access, log | **Routes:** all keyed relay routes

Computes hash of request identity for `limit-count` scoping via header
`X-Key-Hash` (`http_x_key_hash`). Not enabled on llamafile or
`gateway-provider-sync` (those use `remote_addr` for rate limiting).

## kimi-auth

**File:** `kimi-auth.lua` (286 lines); libraries `kimi_device.lua`,
`kimi_jwt.lua`, `kimi_tokens.lua`
**Priority:** 2560 | **Phase:** access | **Routes:** `relay-kimi*`

Kimi OAuth device-code authentication: device flow endpoints, JWT handling,
token storage/refresh, and upstream credential injection for Kimi routes.

## provider-sync

**File:** `provider-sync.lua` (211 lines); libraries
`provider_sync_catalog.lua` (507 lines), `provider_sync_pricing.lua` (105 lines)
**Priority:** 2570 | **Phase:** access (+ `plugin.init()` warmup timer)
**Route:** `gateway-provider-sync` (`/gateway/providers*`)

Gateway-managed provider catalog and client config service. Reads static
provider definitions from `conf/providers/*.yaml`, enriches with model
metadata and pricing, and serves read-only HTTP endpoints (including
`POST /gateway/providers/sync`) directly in the access phase.
`provider_sync_pricing` is the sole writer of `pricing:*` keys in the
`gateway-cache` shared dict, keyed by canonical model id.

## redact

**Files:** `redact.lua` (195 lines), `redact_lib.lua` (100 lines)
**Priority:** 2500 | **Phases:** access, header_filter, body_filter, log

Loads `conf/redact-patterns.json`. Replaces PII in request `messages[]`
with tokens (`[EMAIL_1]`, etc.), re-hydrates in response `body_filter`.
Luhn check on credit card patterns.

## sse-usage

**Files:** `sse-usage.lua` (320 lines), `sse_usage_lib.lua` (116 lines)
**Priority:** 2400 | **Phases:** access, header_filter, body_filter, log

Extracts `usage` and model from SSE final chunk or JSON body. Inserts
`usage_log` via `ngx.timer.at(0, ...)` (cosockets forbidden in log phase).
Retries ClickHouse INSERT 3x with backoff. Cost fields come from
`cost_calc` (`get_pricing`, `compute_cost`, `resolve_cost`).

### usage_log columns (inserted)

`event_id`, `request_id`, `model`, token breakdown, `key_id`, `api_key_id`,
`aborted`, `is_stream`, `cost`, `cost_source`, `timestamp`. Full schema:
[`TELEMETRY-AND-SCHEMA.md`](TELEMETRY-AND-SCHEMA.md).

## Library modules (not registered plugins)

| Module | Lines | Purpose |
|--------|-------|---------|
| `cost_calc.lua` | 149 | Read-only pricing consumer: `get_pricing` / `compute_cost` / `resolve_cost` |
| `model_registry.lua` | 64 | GENERATED from `conf/model-registry.yaml` (alias map, canonical ids); regenerate via `res/scripts/gen-model-registry.sh` |
| `provider_sync_catalog.lua` | 507 | Provider/model catalog for `provider-sync` |
| `provider_sync_pricing.lua` | 105 | Pricing sync; sole writer of `pricing:*` |
| `sse_usage_lib.lua` | 116 | Pure logic for `sse-usage` |
| `redact_lib.lua` | 100 | Pure logic for `redact` |
| `kimi_device.lua` / `kimi_jwt.lua` / `kimi_tokens.lua` | 150/60/104 | `kimi-auth` helpers |
