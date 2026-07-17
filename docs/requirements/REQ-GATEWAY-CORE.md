# REQ-GATEWAY-CORE: APISIX Gateway Core

**Date:** 2026-07-17
**Status:** Active
**Type:** Requirements
**Specification:** [SPEC-GATEWAY-CORE](../specifications/SPEC-GATEWAY-CORE.md)

> Mandates the APISIX gateway core: deployment in traditional/etcd mode, the 10 relay routes and their auth modes, upstreams (OpenCode relay, Moonshot Kimi, llamafile VM, local Admin API), and the built-in/custom plugin configuration per route. Single source of truth: [`conf/apisix.yaml`](../../conf/apisix.yaml) (routes) and [`conf/config.yaml`](../../conf/config.yaml) (deployment + plugin registration). Excluded: telemetry schema, cost calculation, and plugin-internal contracts (owned by REQ-BILLING-TELEMETRY, REQ-COST-CALC, SPEC-PLUGIN-FOUNDATION).

---

**Cross-references:**
- [SPEC-GATEWAY-CORE](../specifications/SPEC-GATEWAY-CORE.md): companion specification
- [`conf/apisix.yaml`](../../conf/apisix.yaml): owns the 10 route definitions
- [`conf/config.yaml`](../../conf/config.yaml): owns deployment mode and plugin registration
- [`docs/runbooks/RUNBOOK-DEPLOYMENT.md`](../runbooks/RUNBOOK-DEPLOYMENT.md): compose stack and operational commands
- [`docs/architecture/OVERVIEW.md`](../../docs/architecture/OVERVIEW.md): system overview

---

## 1. Purpose & Scope

### 1.1 Purpose
Define the required behavior of the gateway data plane: how it is deployed, which routes exist, how each route authenticates callers, which upstream it relays to, and which plugins run on each route.

### 1.2 Scope
**This document OWNS the requirements for:**
- Deployment mode (traditional, etcd config provider)
- The 10 routes: ids, URI prefixes, upstreams, auth modes
- Per-route plugin attachment (built-in and custom)
- Plugin registration in the APISIX config

**This document DOES NOT:**
- Define ClickHouse schema or the telemetry pipeline (REQ-BILLING-TELEMETRY)
- Define pricing/cost logic (REQ-COST-CALC)
- Define custom plugin manifest/schema/phase contracts (SPEC-PLUGIN-FOUNDATION)

### 1.3 Terminology
| Term | Definition |
|------|------------|
| Federated route | Route using `key-resolver`: caller presents a `vgw-*` virtual key resolved via OpenBao to a real upstream key |
| Own-key route | Route where the caller's own upstream API key is passed through |
| Key route | Route relaying to an upstream whose key is provisioned gateway-side (no caller key resolution) |
| Traditional mode | APISIX deployment role using etcd as config provider |

## 2. Functional Requirements

### FR-1: Deployment Mode
| ID | Requirement |
|----|-------------|
| FR-1.1 | The gateway MUST run APISIX in `role: traditional` with `role_traditional.config_provider: etcd`. |
| FR-1.2 | The etcd host MUST be `http://etcd:2379` with prefix `/apisix`. |
| FR-1.3 | Route configuration MUST be seeded into etcd (via [`res/scripts/seed-routes.sh`](../../res/scripts/seed-routes.sh)) from the rendered [`conf/apisix.yaml`](../../conf/apisix.yaml) (rendered from `conf/apisix.yaml.j2`); the data plane MUST NOT run in standalone YAML mode. |
| FR-1.4 | The Admin API MUST be protected by an admin key `${{ADMIN_KEY}}` and expose the admin UI. |

### FR-2: Routes
| ID | Requirement |
|----|-------------|
| FR-2.1 | The gateway MUST define exactly 10 routes: `relay-opencode`, `relay-opencode-federated`, `relay-kimi`, `relay-kimi-v1`, `relay-kimi-federated`, `relay-kimi-federated-v1`, `relay-kimi-key`, `relay-kimi-key-v1`, `relay-llamafile`, `gateway-provider-sync`. |
| FR-2.2 | `relay-opencode` (`/opencode/*`) MUST proxy-rewrite to `/zen/go/$1` on upstream `opencode.ai:443` (https, pass_host node) and MUST NOT attach `key-resolver` (direct key passthrough). |
| FR-2.3 | `relay-opencode-federated` (`/opencode_federated/*`) MUST rewrite to `/zen/go/$1` on `opencode.ai:443` and MUST attach `key-resolver` with `upstream_key_env: OPENCODE_API_KEY` and `virtual_key_prefix: vgw-`. |
| FR-2.4 | `relay-kimi` (`/kimi/*`) and `relay-kimi-v1` (`/kimi/v1/*`) MUST rewrite to `/coding/v1/$1` on `api.kimi.com:443` and MUST attach `kimi-auth` (federated OAuth device-flow auth). |
| FR-2.5 | `relay-kimi-federated` (`/kimi-federated/*`) and `relay-kimi-federated-v1` (`/kimi-federated/v1/*`) MUST rewrite to `/coding/v1/$1` on `api.kimi.com:443` and MUST attach `key-resolver` with `upstream_key_env: KIMI_API_KEY`. |
| FR-2.6 | `relay-kimi-key` (`/kimi-key/*`) and `relay-kimi-key-v1` (`/kimi-key/v1/*`) MUST rewrite to `/coding/v1/$1` on `api.kimi.com:443` and MUST attach neither `kimi-auth` nor `key-resolver` (gateway-provisioned key / passthrough). |
| FR-2.7 | `relay-llamafile` (`/llamafile/*`) MUST rewrite to `/$1` on `host.docker.internal:8765` over http (local llamafile VM, no auth plugin). |
| FR-2.8 | `gateway-provider-sync` (`/gateway/providers*`) MUST target `127.0.0.1:9080` (http, pass_host pass) and MUST attach the `provider-sync` plugin. |

### FR-3: Built-in Plugins on Relay Routes
| ID | Requirement |
|----|-------------|
| FR-3.1 | Every relay route MUST attach `http-logger` posting to `http://vector:8080/ingest` with request and response bodies (`max_req_body_bytes: 262144`, `max_resp_body_bytes: 1048576`, `batch_max_size: 1`). |
| FR-3.2 | Every route MUST attach `prometheus` with `prefer_name: true` and `request-id` with header `X-Request-Id` included in the response. |
| FR-3.3 | Every relay route MUST attach `proxy-buffering` with `disable: true` (SSE streaming) and `proxy-rewrite` with the route's regex_uri. |
| FR-3.4 | Relay routes with keyed callers (opencode, kimi families) MUST attach `limit-count` with `count: 100`, `time_window: 60`, `rejected_code: 429`, keyed on `http_x_key_hash`, policy `local`. |
| FR-3.5 | `relay-llamafile` MUST use `limit-count` `count: 600` keyed on `remote_addr`; `gateway-provider-sync` MUST use `count: 60` keyed on `remote_addr`. |
| FR-3.6 | Every relay route MUST attach the custom `redact` plugin with `patterns_file: /etc/apisix/redact-patterns.json` and the custom `sse-usage` plugin with `clickhouse_addr: http://clickhouse:8123`. |
| FR-3.7 | Keyed relay routes MUST attach `key-meta` to emit the `X-Key-Hash` header used by limit-count and Prometheus labels. |

### FR-4: Plugin Registration
| ID | Requirement |
|----|-------------|
| FR-4.1 | [`conf/config.yaml`](../../conf/config.yaml) MUST register custom plugins `key-resolver`, `key-meta`, `kimi-auth`, `provider-sync`, `sse-usage`, `redact` in the `plugins:` list. |
| FR-4.2 | The `plugins:` list MUST also include built-ins used on routes: `ai-rate-limiting`, `proxy-buffering`, `proxy-rewrite`, `http-logger`, `prometheus`, `request-id`, `limit-count`. |
| FR-4.3 | Lua shared dicts `redact_state: 1m`, `key_cache: 5m`, `gateway-cache: 2m`, `quota_counters: 5m` MUST be declared under `nginx_config.http.custom_lua_shared_dict`. |
| FR-4.4 | Prometheus plugin_attr MUST export on `0.0.0.0:9100` and MUST add the `key_hash` extra label (from `$http_x_key_hash`) to http_status, http_latency, bandwidth, and llm_* metrics. |
| FR-4.5 | `OPENCODE_API_KEY` and `OPENBAO_TOKEN` MUST be declared under `nginx_config.envs`. |

## 3. Non-Functional Requirements
| ID | Requirement |
|----|-------------|
| NFR-1.1 | All request-time logic MUST run in pure Lua inside the nginx worker; no sidecars on the request path. |
| NFR-1.2 | SSE responses MUST NOT be buffered (proxy-buffering disabled on relay routes). |
| NFR-1.3 | Secrets (upstream keys, OpenBao token) MUST be injected via environment variables, never committed to config files. |

## 4. Constraints
| ID | Constraint | Source |
|----|-----------|--------|
| C-1 | APISIX 3.17.0 (`apache/apisix:3.17.0-debian`) | RUNBOOK-DEPLOYMENT |
| C-2 | etcd config provider is mandatory; standalone YAML mode is not used | conf/config.yaml |
| C-3 | `docs/architecture/TELEMETRY-AND-SCHEMA.md` path is critical for tests | tests/config/test_migrations.sh |

## 5. Assumptions
| ID | Assumption |
|----|-----------|
| A-1 | `opencode.ai` and `api.kimi.com` are reachable over TLS from the stack. |
| A-2 | The llamafile VM listens on `host.docker.internal:8765`. |

## 6. Open Questions
None.

## 7. Verification Matrix
| # | Test | Maps to |
|---|------|---------|
| V1 | `tests/config/test_apisix_yaml.sh` validates routes/plugins in conf/apisix.yaml | FR-2.x, FR-3.x |
| V2 | `tests/config/test_apisix_yaml_render.sh` validates J2 rendering | FR-1.3 |
| V3 | `tests/config/test_config_yaml.sh` validates plugin registration and shared dicts | FR-4.x |
| V4 | `tests/config/test_compose.sh` validates stack wiring | FR-1.x |
| V5 | `tests/integration/test_route_relay.sh` exercises relay routes | FR-2.x |

## 8. Implementation Status
| Item | Status | Evidence |
|------|--------|----------|
| FR-1.1-FR-1.4 | Implemented | conf/config.yaml:5-21 |
| FR-2.1-FR-2.8 | Implemented | conf/apisix.yaml (10 routes) |
| FR-3.1-FR-3.7 | Implemented | conf/apisix.yaml plugin blocks |
| FR-4.1-FR-4.5 | Implemented | conf/config.yaml:23-75 |
| NFR-1.1-1.3 | Implemented | docs/architecture/OVERVIEW.md; no sidecars in res/docker |
