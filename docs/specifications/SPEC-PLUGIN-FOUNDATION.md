# SPEC-PLUGIN-FOUNDATION: Custom Plugin Foundation Implementation

**Date:** 2026-07-17
**Status:** Active
**Type:** Specification
**Requirements:** [REQ-GATEWAY-CORE](../requirements/REQ-GATEWAY-CORE.md)

> Corrected engineering foundation for the custom Lua plugins in [`plugins/custom/`](../../plugins/custom). Key correction over the legacy foundation doc: deployment is **traditional role with etcd config provider**  -  NOT "standalone YAML, no etcd" as the old doc claimed. Plugins are COPYed flat into `apisix/plugins/` and registered by name in `conf/config.yaml`.

---

**Cross-references:**
- [REQ-GATEWAY-CORE](../requirements/REQ-GATEWAY-CORE.md): deployment and registration requirements
- [`plugins/custom/`](../../plugins/custom): plugin and library sources
- [`conf/config.yaml`](../../conf/config.yaml): plugin registration, shared dicts
- [`conf/apisix.yaml`](../../conf/apisix.yaml): per-route plugin configs
- [`res/docker/Dockerfile.apisix`](../../res/docker/Dockerfile.apisix): image layout


---

## 1. Overview

All request-time logic is pure Lua running in-process inside the APISIX nginx worker (LuaJIT, OpenResty cosockets). No Wasm, no Rust sidecar. Six registered plugins plus shared libraries cover auth (kimi-auth, key-resolver), key scoping (key-meta), PII redaction (redact), usage accounting (sse-usage), and provider catalog/pricing sync (provider-sync).

## 2. Architectural Principles

### 2.1 Target platform

| Component | Value |
|-----------|-------|
| APISIX | 3.17.0 (`apache/apisix:3.17.0-debian`) |
| Deployment | `role: traditional`, `config_provider: etcd` (`http://etcd:2379`, prefix `/apisix`)  -  routes seeded to etcd, NOT standalone YAML |
| Lua | LuaJIT 2.1 (bundled with the image) |

### 2.2 Flat plugin layout
The old doc's `extra_lua_path` + `apisix/plugins/custom/` layout is NOT used. The Dockerfile COPYs each `plugins/custom/*.lua` flat to `/usr/local/apisix/apisix/plugins/<name>.lua`; plugins are required as `apisix.plugins.<name>` and enabled by listing the name under `plugins:` in `conf/config.yaml`.

### 2.3 Plugins vs libraries
Registered APISIX plugins (manifest + schema + phases): `key-resolver`, `key-meta`, `kimi-auth`, `provider-sync`, `redact`, `sse-usage`. Pure Lua modules required by them (not registered): `cost_calc`, `model_registry`, `sse_usage_lib`, `redact_lib`, `provider_sync_catalog`, `provider_sync_pricing`, `kimi_device`, `kimi_jwt`, `kimi_tokens`.

## 3. Plugin Contracts

### 3.1 Manifest
Every plugin returns a table with `version`, `priority`, `name`:

| Plugin | Priority | Phases implemented |
|--------|----------|--------------------|
| sse-usage | 2400 | init, access, header_filter, body_filter, log |
| redact | 2500 | access, header_filter, body_filter, log |
| key-meta | 2530 | access, log |
| key-resolver | 2555 | access |
| kimi-auth | 2560 | access |
| provider-sync | 2570 | init, access |

Higher priority runs earlier: auth (`kimi-auth` 2560, `key-resolver` 2555) precedes key scoping (`key-meta` 2530), redaction (2500), and usage logging (2400).

### 3.2 Schema
Each plugin defines `plugin.schema` (Lua table, APISIX schema DSL) and `plugin.check_schema(conf)` delegating to `core.schema.check`. Examples: `sse-usage` has `clickhouse_addr` (default `http://clickhouse:8123`); `redact` has `patterns_file`; `key-resolver` has `openbao_addr`, `openbao_token_env`, `upstream_key_env`, `key_prefix`, `cache_ttl`, `virtual_key_prefix`; `kimi-auth` and `key-meta` accept empty objects `{}`.

### 3.3 Phase semantics
- `access`  -  auth resolution, key scoping, request-body model capture, PII anonymization.
- `header_filter` / `body_filter`  -  streaming response observation (usage scanning, re-hydration).
- `log`  -  telemetry writes, always off the blocking path (`ngx.timer.at` for HTTP INSERTs).
- `init`  -  one-time warmup (provider-sync catalog/pricing seed).

### 3.4 Shared state
`nginx_config.http.custom_lua_shared_dict`: `redact_state: 1m`, `key_cache: 5m`, `gateway-cache: 2m` (pricing/catalog), `quota_counters: 5m`. Secrets arrive via `nginx_config.envs` (`OPENCODE_API_KEY`, `OPENBAO_TOKEN`).

## 4. File Inventory

| File | Kind | Role |
|------|------|------|
| key-resolver.lua | plugin | `vgw-*` virtual keys via OpenBao; passthrough otherwise |
| key-meta.lua | plugin | emits `X-Key-Hash` for per-key scoping |
| kimi-auth.lua | plugin | Kimi device-flow OAuth (uses kimi_device/kimi_jwt/kimi_tokens) |
| provider-sync.lua | plugin | `/gateway/providers*` endpoint + catalog/pricing sync |
| redact.lua | plugin | PII anonymize + re-hydrate (uses redact_lib) |
| sse-usage.lua | plugin | SSE/JSON usage extraction, usage_log INSERT, quota counters |
| cost_calc.lua | module | read-only pricing consumer |
| model_registry.lua | module | canonical model ids (generated from conf/model-registry.yaml) |
| provider_sync_catalog.lua / provider_sync_pricing.lua | modules | catalog fetch; sole `pricing:*` writer |
| redact_lib.lua / sse_usage_lib.lua | modules | pure-logic libs (unit-testable in LuaJIT) |
| kimi_device.lua / kimi_jwt.lua / kimi_tokens.lua | modules | Kimi OAuth helpers |

## 5. Edge Cases & Decisions

- The legacy doc's claim of `deployment.role: data_plane` / `config_provider: yaml` is wrong for this repo; corrected to traditional/etcd (see REQ-GATEWAY-CORE FR-1).
- The legacy doc's `semantic-cache` plugin does not exist in the codebase; it is not described here.
- `redact-patterns.json` (not `.yaml`) is the actual patterns file, mounted at `/etc/apisix/redact-patterns.json`.
- Library modules use deferred requires so they run under plain LuaJIT in `tests/lua/`.

## 6. File Map

| File | Purpose | Key Changes |
|------|---------|-------------|
| [`plugins/custom/`](../../plugins/custom) | Plugin + module sources (15 files) |  -  |
| [`res/docker/Dockerfile.apisix`](../../res/docker/Dockerfile.apisix) | Flat COPY into apisix/plugins/ |  -  |
| [`conf/config.yaml`](../../conf/config.yaml) | Registration, shared dicts, envs |  -  |
| [`conf/apisix.yaml`](../../conf/apisix.yaml) | Per-route plugin attachment |  -  |
| [`tests/lua/`](../../tests/lua) | LuaJIT unit tests for libs |  -  |

## 7. Implementation Status

| Component | Status | Evidence |
|-----------|--------|----------|
| 6 registered plugins | Implemented | conf/config.yaml:23-36; plugins/custom/*.lua manifests |
| Flat COPY image layout | Implemented | res/docker/Dockerfile.apisix:3-17 |
| etcd/traditional deployment | Implemented | conf/config.yaml:5-21 |
| Shared dicts + envs | Implemented | conf/config.yaml:65-75 |
| semantic-cache plugin | Not implemented | referenced only in legacy docs; no source file |
