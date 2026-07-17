# REQ-BILLING-TELEMETRY: Billing-Grade Telemetry

**Date:** 2026-07-17
**Status:** Active
**Type:** Requirements
**Specification:** [SPEC-BILLING-TELEMETRY](../specifications/SPEC-BILLING-TELEMETRY.md)

> Mandates the billing telemetry pipeline: two write paths into ClickHouse (`http-logger` → Vector → `request_log`; `sse-usage` timer → `usage_log`) plus a materialized view into `billing_ledger`, canonical model identity (`model` + `model_raw`), the 4-table schema contract with 5 migrations, and a daily reconciler. Single source of truth: [`conf/clickhouse-init.sql`](../../conf/clickhouse-init.sql), [`conf/migrations/`](../../conf/migrations), [`conf/vector.toml`](../../conf/vector.toml), [`plugins/custom/sse-usage.lua`](../../plugins/custom/sse-usage.lua). Excluded: pricing lookup internals (REQ-COST-CALC).

---

**Cross-references:**
- [SPEC-BILLING-TELEMETRY](../specifications/SPEC-BILLING-TELEMETRY.md): companion specification
- [`docs/architecture/TELEMETRY-AND-SCHEMA.md`](../../docs/architecture/TELEMETRY-AND-SCHEMA.md): critical architecture doc (path checked by tests/config/test_migrations.sh)
- [`conf/clickhouse-init.sql`](../../conf/clickhouse-init.sql): owns the table schemas
- [`conf/vector.toml`](../../conf/vector.toml): owns the Vector pipeline
- [`plugins/custom/sse-usage.lua`](../../plugins/custom/sse-usage.lua): owns usage_log writes

---

## 1. Purpose & Scope

### 1.1 Purpose
Guarantee billing-grade accounting: every request leaves an auditable trail of tokens, cost, and identity, joinable across tables, with a reconciliation process for divergence detection.

### 1.2 Scope
**This document OWNS the requirements for:**
- Token accounting (authoritative usage source per response type)
- ClickHouse schema contract (4 tables + 5 migrations + 1 MV)
- Vector pipeline behavior incl. model canonicalization
- Model identity (`model` canonical, `model_raw` verbatim)
- Reconciler behavior

**This document DOES NOT:**
- Define pricing rates or cost math (REQ-COST-CALC)
- Define Grafana dashboards (REQ-DASHBOARD / SPEC-DASHBOARD)

### 1.3 Terminology
| Term | Definition |
|------|------------|
| event_id | `route_id .. "_" .. floor(start_time)`; correlation id produced identically by Vector and sse-usage |
| request_id | `X-Request-Id` header set by the APISIX request-id plugin; join key between request_log and usage_log |
| cost_source | Enum8: `upstream` (0), `computed` (1), `unknown` (2) |
| Canonical model | Model id produced by `model_registry.canonical()` from `conf/model-registry.yaml` |

## 2. Functional Requirements

### FR-1: Write Paths
| ID | Requirement |
|----|-------------|
| FR-1.1 | APISIX `http-logger` MUST POST every request/response (with bodies, truncated at 256 KiB / 1 MiB) to Vector at `http://vector:8080/ingest`. |
| FR-1.2 | Vector MUST remap each event and batch-insert into `llm_gateway.request_log` with retry (5 attempts, backoff, memory buffer with block-when-full). |
| FR-1.3 | The `sse-usage` plugin MUST extract usage from SSE streams and JSON responses and MUST INSERT one row per tracked request into `llm_gateway.usage_log` via `POST ... INSERT INTO llm_gateway.usage_log FORMAT JSONEachRow` from an `ngx.timer.at` context (not the request path). |
| FR-1.4 | usage_log INSERTs MUST retry up to 3 times (delays 0.1s, 0.5s, 2.0s) and MUST log errors on failure; divergence data MUST NOT be silently discarded. |
| FR-1.5 | For SSE responses, usage_log MUST be the authoritative token source (request_log token fields may be 0 for SSE). |

### FR-2: Correlation
| ID | Requirement |
|----|-------------|
| FR-2.1 | Both Vector and sse-usage MUST compute `event_id` as `route_id + "_" + floor(start_time_seconds)` from the same nginx `$start_time` source. |
| FR-2.2 | Both paths MUST record `request_id` from the `X-Request-Id` request header; joins MUST use `request_id`. |
| FR-2.3 | Both paths MUST compute `key_id` identically: prefer `x-gateway-key-id`; if empty or `passthrough`, use the Bearer token; hash with SHA-256 truncated to 16 hex chars. |

### FR-3: ClickHouse Schema Contract
| ID | Requirement |
|----|-------------|
| FR-3.1 | Database `llm_gateway` MUST contain tables `request_log`, `usage_log`, `billing_ledger`, `billing_discrepancies` as defined in [`conf/clickhouse-init.sql`](../../conf/clickhouse-init.sql). |
| FR-3.2 | `usage_log` MUST include columns: event_id, request_id, model, model_raw, prompt/completion/total/cached/reasoning tokens, key_id, api_key_id, aborted (UInt8), is_stream (UInt8), cost (Float64), cost_source (Enum8 upstream/computed/unknown), timestamp. |
| FR-3.3 | `billing_ledger` MUST be auto-populated by materialized view `billing_ledger_mv` on every usage_log INSERT, deriving `request_mode` (stream/batch), `cache_status` (hit/miss), `success`, and `error_type`. |
| FR-3.4 | `billing_discrepancies` MUST exist as the reconciler target (columns date, tenant_id, provider, model_name, gateway_tokens, provider_tokens, divergence, tolerance, flagged_at). |
| FR-3.5 | Schema evolution MUST go through golang-migrate migrations `000001`-`000005` in [`conf/migrations/`](../../conf/migrations), each idempotent with `.up.sql`/`.down.sql` pairs. |
| FR-3.6 | All MergeTree tables MUST partition by month and carry a 13-month TTL (except billing_discrepancies, which partitions by month with no TTL). |

### FR-4: Model Canonicalization
| ID | Requirement |
|----|-------------|
| FR-4.1 | `conf/model-registry.yaml` MUST be the single source of truth for model identity, codegenned by `res/scripts/gen-model-registry.sh` into `plugins/custom/model_registry.lua` and the GENERATED block in `conf/vector.toml`. |
| FR-4.2 | Both Vector (request_log.model) and sse-usage (usage_log.model) MUST store the canonical id; the verbatim wire string MUST be preserved in `model_raw`. |
| FR-4.3 | The canonicalization algorithm MUST be: lowercase exact hit in alias map; else last-slash-segment hit; else the last segment itself. |

### FR-5: Cost Computation Ownership
| ID | Requirement |
|----|-------------|
| FR-5.1 | Cost MUST be resolved by `cost_calc.resolve_cost` inside sse-usage: upstream-reported cost wins; otherwise computed from the pricing cache; otherwise `cost_source = unknown`. |
| FR-5.2 | `billing_ledger_mv` MUST copy cost rounded to 6 decimals; rate_input/rate_output default to 0 until a pricing snapshot lands in ClickHouse. |

### FR-6: Reconciler
| ID | Requirement |
|----|-------------|
| FR-6.1 | [`res/scripts/reconciler.sh`](../../res/scripts/reconciler.sh) MUST compute daily gateway-side per-provider/model token totals from `request_log` for the previous day. |
| FR-6.2 | Reconciler output MUST be logged for audit; upstream provider API comparison and insertion into `billing_discrepancies` is deferred (v2)  -  until then the table stays empty and no divergence is discarded. |

## 3. Non-Functional Requirements
| ID | Requirement |
|----|-------------|
| NFR-1.1 | Telemetry writes MUST NOT block the request path (timer-based INSERTs, batched Vector sink). |
| NFR-1.2 | Telemetry failures MUST be logged (`core.log.error` / Vector retries) and MUST NOT fail client requests. |
| NFR-1.3 | Key material MUST never be stored in telemetry; only 16-char SHA-256 prefixes (`key_id`). |

## 4. Constraints
| ID | Constraint | Source |
|----|-----------|--------|
| C-1 | golang-migrate `migrate/migrate:v4.19.1`; `schema_migrations` tracking table | docs/architecture/TELEMETRY-AND-SCHEMA.md |
| C-2 | ClickHouse 24.8 cannot MODIFY ORDER BY on populated MergeTree (migration 000003 is a documented no-op) | conf/migrations/000003 |
| C-3 | TELEMETRY-AND-SCHEMA.md path is critical for tests | tests/config/test_migrations.sh |

## 5. Assumptions
| ID | Assumption |
|----|-----------|
| A-1 | http-logger `start_time` arrives in milliseconds; nginx `$start_time` is seconds.millis  -  both floor to the same integer second. |
| A-2 | Vector and ClickHouse are on the same compose network (`vector`, `clickhouse` hostnames). |

## 6. Open Questions
| Q | A |
|---|---|
| Upstream API reconciliation? | Deferred to v2; reconciler logs gateway totals only. |
| Enrichment of tenant_id/user_id/rates in billing_ledger? | Defaults empty/0; a future enrich job backfills via the request_id join key. |

## 7. Verification Matrix
| # | Test | Maps to |
|---|------|---------|
| V1 | `tests/config/test_clickhouse_sql.sh` | FR-3.1-3.4 |
| V2 | `tests/config/test_migrations.sh` | FR-3.5 |
| V3 | `tests/config/test_vector_toml.sh` | FR-1.2, FR-4.x |
| V4 | `tests/config/test_model_registry.sh` (codegen drift) | FR-4.1 |
| V5 | `tests/integration/test_event_id_alignment.sh`, `lib_event_align.sh` | FR-2.1 |
| V6 | `tests/reconciler/test_reconciler.sh`, `tests/integration/test_reconciler_exec.sh` | FR-6.x |
| V7 | `tests/lua/test_sse_usage_lib.lua` | FR-1.3 |

## 8. Implementation Status
| Item | Status | Evidence |
|------|--------|----------|
| FR-1.1-1.5 write paths | Implemented | conf/apisix.yaml http-logger; conf/vector.toml; plugins/custom/sse-usage.lua:140-298 |
| FR-2.1-2.3 correlation | Implemented | conf/vector.toml:94-102; sse-usage.lua:193-232 |
| FR-3.1-3.6 schema + MV | Implemented | conf/clickhouse-init.sql; conf/migrations/000001-000005 |
| FR-4.1-4.3 canonicalization | Implemented | conf/model-registry.yaml; vector.toml GENERATED block; sse-usage.lua:186-191 |
| FR-5.1-5.2 cost ownership | Implemented | sse-usage.lua:166-170; clickhouse-init.sql MV |
| FR-6.1 reconciler totals | Implemented | res/scripts/reconciler.sh |
| FR-6.2 upstream comparison | Not implemented | reconciler.sh v2 comment; billing_discrepancies empty |
