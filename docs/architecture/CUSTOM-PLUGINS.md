# Custom Plugins

Extract-testable-core: `*_lib.lua` (pure logic) + `*.lua` (APISIX adapter).
Deep redact spec: [`PLUGIN-REDACT-LUA.md`](../PLUGIN-REDACT-LUA.md). Cost:
[`COST-CALC-LUA.md`](../COST-CALC-LUA.md).

## key-resolver

**File:** `plugins/custom/key-resolver.lua` (235 lines)  
**Priority:** 2555 | **Phase:** access | **Routes:** federated only

- `vgw-*`: OpenBao lookup, cache in `key_cache`, inject upstream `Authorization`
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

**File:** `plugins/custom/key-meta.lua` (61 lines)  
**Priority:** 2530 | **Phase:** access | **Routes:** opencode + federated

Computes hash of identity for `limit-count` scoping via header
`X-Key-Hash` (`http_x_key_hash`). Not enabled on llamafile (uses
`remote_addr` for rate limit instead).

## redact

**Files:** `redact.lua` (195 lines), `redact_lib.lua` (100 lines)  
**Priority:** 2500 | **Phases:** access, header_filter, body_filter, log

Loads `conf/redact-patterns.json` (cached 60s in `redact_state` dict).
Replaces PII in request `messages[]` with tokens (`[EMAIL_1]`, etc.),
re-hydrates in response `body_filter`. Luhn check on credit card patterns.

## sse-usage

**Files:** `sse-usage.lua` (306 lines), `sse_usage_lib.lua` (116 lines)  
**Priority:** 2400 | **Phases:** header_filter, body_filter, log

Extracts `usage` and model from SSE final chunk or JSON body. Inserts
`usage_log` via `ngx.timer.at(0, ...)` (cosockets forbidden in log phase).
Retries ClickHouse INSERT 3x with backoff.

Uses `cost_calc.normalize_key` for model and `compute_cost` for billing fields.

### usage_log columns (inserted)

`event_id`, `request_id`, `model`, token breakdown, `key_id`, `api_key_id`,
`aborted`, `is_stream`, `cost`, `cost_source`, `timestamp`. Full schema:
[`TELEMETRY-AND-SCHEMA.md`](TELEMETRY-AND-SCHEMA.md).

## cost_calc (library)

**File:** `plugins/custom/cost_calc.lua` (262 lines)  
Not registered in `plugins` list. Required by `sse-usage` for
`normalize_key` and `compute_cost`.