# SPEC-BILLING-TELEMETRY: Billing Telemetry Implementation

**Date:** 2026-07-17
**Status:** Active
**Type:** Specification
**Requirements:** [REQ-BILLING-TELEMETRY](../requirements/REQ-BILLING-TELEMETRY.md)

> Implements billing-grade telemetry on ClickHouse: Vector-remapped `request_log`, timer-written `usage_log`, MV-populated `billing_ledger`, and a `billing_discrepancies` reconciler target. Invariants: identical `event_id`/`request_id`/`key_id` derivation on both write paths; canonical `model` + verbatim `model_raw`; all schema change via golang-migrate.

---

**Cross-references:**
- [REQ-BILLING-TELEMETRY](../requirements/REQ-BILLING-TELEMETRY.md): requirements
- [`conf/clickhouse-init.sql`](../../conf/clickhouse-init.sql): tables + billing_ledger_mv
- [`conf/migrations/`](../../conf/migrations): 000001-000005 up/down pairs
- [`conf/vector.toml`](../../conf/vector.toml): source → remap → ClickHouse sink
- [`plugins/custom/sse-usage.lua`](../../plugins/custom/sse-usage.lua): usage_log writer
- [`plugins/custom/sse_usage_lib.lua`](../../plugins/custom/sse_usage_lib.lua): SSE/JSON parsing lib
- [`res/scripts/reconciler.sh`](../../res/scripts/reconciler.sh): daily totals job
- [`docs/architecture/TELEMETRY-AND-SCHEMA.md`](../../docs/architecture/TELEMETRY-AND-SCHEMA.md): architecture doc (critical path)

---

## 1. Overview

Two independent write paths converge on shared correlation ids:

1. **request_log path**  -  APISIX `http-logger` → Vector `http_server` source → VRL remap → ClickHouse `request_log`.
2. **usage_log path**  -  `sse-usage` plugin observes the stream in `body_filter`, resolves cost in `log`, and INSERTs into `usage_log` from an `ngx.timer.at` context.

`billing_ledger_mv` fires on each usage_log INSERT to populate `billing_ledger`. The reconciler reads `request_log` daily.

## 2. Architectural Principles

### 2.1 Off-path durability
No telemetry write blocks a client response: Vector batches with retry; sse-usage INSERTs from a timer with 3 retries.

### 2.2 Deterministic correlation
`event_id = route_id + "_" + floor(start_time)`. Vector receives `start_time` in ms from http-logger and truncates; sse-usage floors `ngx.var.start_time` (seconds.millis). Both agree on the integer second. `request_id` comes from the `X-Request-Id` header set by the request-id plugin; both sides fall back consistently.

### 2.3 Canonical model identity
`conf/model-registry.yaml` is codegen'd into `model_registry.lua` and the Vector GENERATED block. `model`/`model_name` columns hold the canonical id; `model_raw` holds the verbatim wire string (migration 000005).

### 2.4 Immutable schema history
golang-migrate versions 000001-000005; `000003` is a recorded no-op (ClickHouse 24.8 cannot MODIFY ORDER BY on populated MergeTree).

## 3. System Diagram

```
        +--------------------- APISIX worker ---------------------+
request |  request-id plugin -> X-Request-Id                      |
------->|  http-logger --POST /ingest--> Vector (http_server)     |
        |                              | remap (VRL)              |
        |                              v                          |
        |                    clickhouse sink -> request_log       |
        |  sse-usage: access/body_filter/log                      |
        |       | ngx.timer.at POST JSONEachRow                   |
        |       v                                                 |
        +-------+-------------------------------------------------+
                v
        usage_log --(billing_ledger_mv)--> billing_ledger
        request_log <-- reconciler.sh (daily totals)
                       (v2: -> billing_discrepancies)
```

## 4. Table Schemas

From [`conf/clickhouse-init.sql`](../../conf/clickhouse-init.sql). All MergeTree, `PARTITION BY toYYYYMM`, `SETTINGS index_granularity = 8192`, 13-month TTL (except billing_discrepancies).

### 4.1 request_log (written by Vector)
ORDER BY `(provider, model, timestamp)`. Columns: `event_id`, `provider`, `model`, `stream`, `method`, `uri`, `status`, `upstream_response_time_s`, `request_size`, `response_size`, `client_ip`, `api_key_id`, `tenant_id`, `user_id`, `key_id`, `session_id`, `request_id`, `project_id`, `parent_session_id`, `client_type`, `agent_name`, `opencode_version`, `user_agent`, `prompt_tokens`, `completion_tokens`, `total_tokens`, `req_body`, `resp_body`, `redact_active`, `redact_token_count`, `timestamp DateTime64(3)`.

### 4.2 usage_log (written by sse-usage)
ORDER BY `(event_id, request_id, timestamp)`. Columns: `event_id`, `request_id`, `model`, `model_raw`, `prompt_tokens`, `completion_tokens`, `total_tokens`, `cached_tokens`, `reasoning_tokens`, `key_id`, `api_key_id`, `aborted UInt8`, `is_stream UInt8`, `cost Float64`, `cost_source Enum8('upstream'=0,'computed'=1,'unknown'=2)`, `timestamp`.

### 4.3 billing_ledger (populated by MV)
ORDER BY `(tenant_id, user_id, timestamp)`. 25+ columns incl. identity (tenant_id, user_id, provider, model_name, model_raw, route_name, consumer_group), `request_mode`, `cache_status`, token fields, `rate_input/rate_output Decimal64(8)`, `currency`, `cost Decimal64(6)`, `success`, `error_type`, latency fields, `upstream_resp_id`, redact fields. Enrichment-only columns default to `''`/0 until backfill.

### 4.4 billing_discrepancies (reconciler v2 target)
`date Date`, `tenant_id`, `provider`, `model_name`, `gateway_tokens UInt32`, `provider_tokens UInt32`, `divergence Decimal64(6)`, `tolerance Decimal64(6)`, `flagged_at`. No TTL. Empty today.

### 4.5 Migrations
| Version | Change |
|---------|--------|
| 000001 | Add `cost_source` Enum8 to usage_log |
| 000002 | Add `request_id` to usage_log |
| 000003 | Documented no-op (ORDER BY alignment; fresh installs get it from init.sql) |
| 000004 | Create `billing_ledger_mv` |
| 000005 | Add `model_raw` to usage_log + billing_ledger; recreate MV forwarding it |

## 5. Vector Pipeline

[`conf/vector.toml`](../../conf/vector.toml): `http_server` source on `0.0.0.0:8080/ingest` → `remap` transform → `clickhouse` sink (`request_log`, batch 50/1s, memory buffer 10k events block-when-full, 5 retries with backoff).

Remap stages:
1. `provider = "opencode"`; parse request body JSON; `model_raw` = body `model`.
2. **GENERATED canonicalization block** (from `conf/model-registry.yaml` via `res/scripts/gen-model-registry.sh`, never hand-edited): lowercase exact alias hit → last-slash-segment hit → last segment. Result in `.model`.
3. `.stream`, `.method`, `.uri`, sizes; upstream latency ms → seconds.
4. Tokens from `resp_parsed.usage`; SSE fallback: regex-extract `"usage":{...}` from `data:` payload.
5. Identity: `api_key_id` from consumer username; `key_id` = SHA-256(x-gateway-key-id or Bearer token)[:16]; tenant/user/session/parent-session/user-agent from headers.
6. `event_id = route_id + "_" + to_int(start_time_ms / 1000)`; `request_id` from `x-request-id` header; timestamp formatted from `start_time` ms.

## 6. sse-usage Logging Flow

[`plugins/custom/sse-usage.lua`](../../plugins/custom/sse-usage.lua) (priority 2400):

1. `init`  -  triggers `provider-sync.sync({})` so pricing cache is warm.
2. `access`  -  captures request body `model` into `ctx.sse_req_model`.
3. `header_filter`  -  enables tracking for `text/event-stream` (stream) or `application/json` (batch).
4. `body_filter`  -  buffers via `sse_usage_lib.buffer_chunk`; scans complete lines (`scan_sse_for_usage` / `parse_json_usage`) for usage, model, `estimated_cost`, reasoning text; tracks `[DONE]` and upstream EOF.
5. `log`  -  computes `aborted` (0 completed, 1 client abort, 2 provider abort), extracts tokens via `sse_usage_lib.extract_tokens`, resolves cost via `cost_calc.resolve_cost`, canonicalizes model (`model_registry.canonical`, verbatim kept in `model_raw`), builds `event_id`/`request_id`/`key_id`, encodes a JSONEachRow entry and INSERTs into `usage_log` from `ngx.timer.at` with retries {0.1, 0.5, 2.0}s. Also increments the `quota_counters` shared dict when `ctx.quota_bucket_key` is set.

## 7. Reconciler

[`res/scripts/reconciler.sh`](../../res/scripts/reconciler.sh): computes `YESTERDAY` portably (Linux/Darwin), queries `request_log` for per-provider/model `sum(prompt/completion/total tokens)`, and logs each line for audit. v2 (commented in-script): compare against upstream provider usage APIs and INSERT divergences into `billing_discrepancies`; divergences are never discarded. Tests: `tests/reconciler/test_reconciler.sh`, `tests/integration/test_reconciler_exec.sh`.

## 8. Edge Cases & Decisions

- SSE responses aborted before any usage chunk: row still written with tokens 0 and `aborted` 1/2; model falls back to the request body so dashboard filtering works.
- `billing_ledger_mv` hardcodes `provider = 'opencode'`; multi-provider enrichment is a v2 backfill.
- `rate_input/rate_output` are 0 in the MV: pricing lives in the nginx `gateway-cache` dict, not ClickHouse.
- `key_id` is a 16-char hash prefix  -  no raw keys in telemetry.

## 9. File Map

| File | Purpose | Key Changes |
|------|---------|-------------|
| [`conf/clickhouse-init.sql`](../../conf/clickhouse-init.sql) | DB, 4 tables, billing_ledger_mv |  -  |
| [`conf/migrations/00000[1-5].*.sql`](../../conf/migrations) | Schema evolution |  -  |
| [`conf/vector.toml`](../../conf/vector.toml) | Ingest pipeline + GENERATED canonicalization |  -  |
| [`plugins/custom/sse-usage.lua`](../../plugins/custom/sse-usage.lua) | usage_log writer |  -  |
| [`plugins/custom/sse_usage_lib.lua`](../../plugins/custom/sse_usage_lib.lua) | chunk buffering, usage scanning, token extraction |  -  |
| [`res/scripts/reconciler.sh`](../../res/scripts/reconciler.sh) | Daily totals |  -  |
| [`docs/architecture/TELEMETRY-AND-SCHEMA.md`](../../docs/architecture/TELEMETRY-AND-SCHEMA.md) | Architecture doc (critical path) |  -  |

## 10. Implementation Status

| Component | Status | Evidence |
|-----------|--------|----------|
| request_log pipeline | Implemented | conf/vector.toml |
| usage_log writer | Implemented | plugins/custom/sse-usage.lua |
| billing_ledger_mv | Implemented | clickhouse-init.sql:190-221; migrations 000004/000005 |
| Migrations 000001-000005 | Implemented | conf/migrations/ |
| Model canonicalization | Implemented | vector.toml GENERATED block; sse-usage.lua:190-191 |
| Reconciler (gateway totals) | Implemented | res/scripts/reconciler.sh |
| Reconciler upstream comparison | Not implemented | v2 comment in reconciler.sh |
