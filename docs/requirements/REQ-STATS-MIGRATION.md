# REQ-STATS-MIGRATION: opencode SQLite Stats Migrator

**Date:** 2026-08-28
**Status:** Implemented (production run complete 2026-08-28)
**Type:** Requirements
**Specification:** [SPEC-STATS-MIGRATION](../specifications/SPEC-STATS-MIGRATION.md)

> Mandates a one-shot, re-runnable migrator that backfills historical usage
> statistics from the opencode client database (`opencode.db`, SQLite) into
> the gateway ClickHouse tables `usage_log` and `request_log`. The migrator
> is read-only against SQLite, deterministic in its ClickHouse row
> identities (idempotent re-runs), and deduplicates by message content at
> extraction time.

---

**Cross-references:**
- [SPEC-STATS-MIGRATION](../specifications/SPEC-STATS-MIGRATION.md): companion specification (field map, dedup keys, algorithm)
- [`conf/clickhouse-init.sql`](../../conf/clickhouse-init.sql): destination schema (ground truth)
- [REQ-BILLING-TELEMETRY](REQ-BILLING-TELEMETRY.md): owner of `usage_log` / `request_log` live write paths
- [TELEMETRY-AND-SCHEMA](../architecture/TELEMETRY-AND-SCHEMA.md): pipeline overview; `billing_ledger_mv` behavior
- [`res/scripts/fix-opencode-empty-parts.sh`](../../res/scripts/fix-opencode-empty-parts.sh): prior art reading the same SQLite source
- [`res/scripts/dedupe-model-history.sh`](../../res/scripts/dedupe-model-history.sh): prior art for ClickHouse mutation scripts

---

## 1. Purpose & Scope

### 1.1 Purpose
Gateway ClickHouse telemetry begins when traffic flows through APISIX.
Assistant turns completed before gateway instrumentation (or bypassing it)
exist only in the opencode client's SQLite database. The migrator makes
that history visible in the existing Grafana cost/usage dashboards and in
`billing_ledger` without any dashboard or ClickHouse schema change.

### 1.2 Scope
**This document OWNS the requirements for:**
- The one-shot migrator script `res/scripts/migrate-opencode-stats.sh`
- Field mapping rules from SQLite `message`/`session` to ClickHouse
  `usage_log` / `request_log`
- Duplicate-detection identity (source-side content dedup + ClickHouse-side
  idempotency)
- Dry-run reporting obligations

**This document DOES NOT:**
- Change the ClickHouse schema (owned by REQ-BILLING-TELEMETRY;
  migration adds no columns or tables)
- Migrate message content into ClickHouse (only numeric/identity stats;
  bodies stay out, unlike live `req_body`/`resp_body`)
- Migrate Prometheus data (Prometheus is scrape-based, holds no history)
- Change Grafana provisioning (existing dashboards query ClickHouse and
  pick migrated rows up automatically)
- Touch `billing_ledger` directly (populated automatically by
  `billing_ledger_mv` on `usage_log` inserts, approved behavior)

## 2. Terminology

| Term | Definition |
|------|------------|
| opencode.db | SQLite client database at `~/.local/share/opencode/opencode.db` (10 GiB, WAL mode, live) |
| assistant message | `message` row with `json_extract(data,'$.role')='assistant'`; the only unit migrated (61,147 rows at probe time) |
| natural key | `(session_id, role, providerID, modelID, time_created, content_hash)`; source-side duplicate identity |
| content_hash | MD5 over the message's `text` and `reasoning` parts, ordered by `part.id` |
| deterministic event_id | `'ocm_' || message.id` (usage_log) / `'ocr_' || message.id` (request_log); makes inserts idempotent |
| TTL-expired | Rows older than the 13-month `TTL` on the destination tables; ClickHouse drops them post-insert |

## 3. Functional Requirements

### FR-1: Source Reading
| ID | Requirement |
|----|-------------|
| FR-1.1 | The migrator MUST open SQLite sources read-only (`file:...?mode=ro` URI) and MUST NOT require opencode to be stopped. |
| FR-1.2 | The migrator MUST read only `message`, `part`, and `session` (+ `project` join for validation). It MUST NOT read `account`, `credential`, `control_account`, `permission`, or `event`: these hold secrets/PII with no stats value. |
| FR-1.3 | Only assistant messages (role = `assistant`) MUST be migrated; user messages carry no tokens/cost (probe: 0 of 7,008 user rows have a `tokens` object). |
| FR-1.4 | The migrator MUST accept an explicit list of source databases (default: `opencode.db` + `opencode-dev.db`) and merge them through the same content dedup; empty schemas MUST be a no-op, not an error. |

### FR-2: Destination Mapping
| ID | Requirement |
|----|-------------|
| FR-2.1 | Every migrated assistant message MUST produce exactly one `usage_log` row and one `request_log` row sharing `request_id = message.id`. |
| FR-2.2 | Token/cost fields MUST come from the message JSON: `tokens.input`→`prompt_tokens`, `tokens.output`→`completion_tokens`, `tokens.reasoning`→`reasoning_tokens`, `tokens.cache.read`→`cached_tokens`, `cost`→`cost`, `time.created` (ms)→`timestamp`. |
| FR-2.3 | `total_tokens` MUST equal `input + output` (live-path default convention in `sse_usage_lib.lua` when upstream reports no total). |
| FR-2.4 | `cost_source` MUST be `'upstream'` when the message cost > 0. When cost = 0, the migrator MUST price the row from the models.dev catalog (per-1M base rates `input`/`output`/`cache_read`, formula mirroring `plugins/custom/cost_calc.lua`: uncached input at `input`, non-reasoning output at `output`, cached at `cache_read`, reasoning at `output`) and mark `cost_source='computed'`; rows on flat-fee subscription providers whose models.dev rates are all zero MUST be priced at the PAYG-equivalent provider via the shadow map (currently `zai-coding-plan`→`zai`). Rows still unpriced keep cost 0 with `cost_source='unknown'`. |
| FR-2.5 | `model` MUST be the canonical id (same algorithm as `conf/model-registry.yaml` codegen: lowercase → alias map → last `/`-segment → alias map); `model_raw` MUST be the verbatim `modelID`. |
| FR-2.6 | `request_log` rows MUST carry the real identity fields available in SQLite (`session_id`, `project_id`, `parent_session_id`, `agent_name`, `opencode_version`, `provider`, `model`, `user_agent`), documented synthetic HTTP fields (`method='POST'`, `uri='/v1/chat/completions'`, `status=200`, `stream=true`, `client_ip='0.0.0.0'`, zero latency), pseudo sizes computed from real part chunks (`request_size` = prior session context bytes, `response_size` = own part bytes), and the marker `client_type='migrated'` so dashboards can filter backfilled rows. |
| FR-2.7 | Synthetic provenance MUST be filterable: migrated rows MUST be identifiable by `event_id LIKE 'ocm_%'` / `'ocr_%'` (live `event_id`s are `route_id + '_' + epoch-seconds` and `msg_...` request_ids never collide with APISIX request ids). |
| FR-2.8 | Fields with no SQLite source (`key_id`, `api_key_id`, `pricing_source`, `pricing_snapshot`, tenant/user identity) MUST take their column defaults (empty/0), exactly as today's `billing_ledger_mv` does. |
| FR-2.9 | `usage_log` inserts MUST flow through `billing_ledger_mv` unmodified (historical cost enters `billing_ledger` with `provider='opencode'`). |

### FR-3: Duplicate Detection & Idempotency
| ID | Requirement |
|----|-------------|
| FR-3.1 | Duplicate identity at source MUST be the natural key `(session_id, role, providerID, modelID, time_created, content_hash)`; within a collision group the migrator MUST keep exactly one row, the lexicographically smallest `message.id` (earliest ULID). |
| FR-3.2 | content_hash MUST be computed over `part.data` of types `text` and `reasoning` only, in `part.id` order, excluding transient types (`step-start`, `step-finish`, `tool`, `patch`, `file`, `compaction`). |
| FR-3.3 | Before each ClickHouse insert batch, the migrator MUST query existing `event_id`s for that batch and skip already-present rows (idempotent re-runs; no double-count in billing). |
| FR-3.4 | Dedup MUST run across all source databases combined (dev-db copies of sessions collapse against main-db originals), not per-database. |

### FR-4: Operational Interface
| ID | Requirement |
|----|-------------|
| FR-4.1 | `--dry-run` MUST report, without writing: per-table row counts to insert, source duplicates collapsed, ClickHouse rows already present, rows older than the 13-month TTL that ClickHouse will expire, and pricing coverage (rows with cost = 0, how many resolve via models.dev, how many stay unknown). |
| FR-4.2 | Inserts MUST be batched (≤ 5,000 rows per HTTP INSERT, `JSONEachRow`) with per-batch failure aborting the run (no silent partial import; safe to re-run). |
| FR-4.3 | The migrator MUST NOT delete or mutate anything in ClickHouse or SQLite. Rollback is `ALTER TABLE ... DELETE WHERE event_id LIKE 'ocm_%'` / `'ocr_%'` (documented in the spec, not automated). |
| FR-4.4 | Exit code MUST be 0 on success (including "nothing to do"), non-zero on any source/destination error. |
| FR-4.5 | `--backup-dir <dir>` MUST, before any insert, dump `usage_log`, `request_log`, and `billing_ledger` as `FORMAT Native` files plus a manifest with row counts and `sum(cityHash64(*))` checksums. The production run against dev MUST use it. |
| FR-4.6 | Rerun gate: when any `ocm_` row already exists in the target, the migrator MUST abort with reset instructions unless `--force` is passed. Stable event ids make plain reruns keep stale rows without any signal, so a re-migration with changed pricing/mapping MUST go through: backup, documented `ocm_%`/`ocr_%` DELETE (mutations_sync=2), verify zero counts, then `--force --backup-dir`. |
| FR-4.7 | The pricing catalog MUST come from models.dev (`MODELS_DEV_URL`, default `https://models.dev/api.json`) or an explicit `--pricing-file <path>`; a missing `--pricing-file` path MUST fail the run, an unreachable URL MUST produce a warning with rows priced as `unknown`. |

### FR-5: Test Isolation
| ID | Requirement |
|----|-------------|
| FR-5.1 | Every test execution of the migrator MUST operate on a COPY of the SQLite source (online `sqlite3 .backup` / `VACUUM INTO`, which checkpoints WAL), never on the live `opencode.db`, and MUST verify the copy is byte-stable for the test duration (no `-wal`/`-shm` side files). |
| FR-5.2 | Every test execution of the migrator MUST target a brand-new, separately provisioned ClickHouse instance (ephemeral container from the same digest-pinned image family as `tests/docker-compose.test.yml`, `conf/clickhouse-init.sql` applied, fresh empty volume), never the dev stack's ClickHouse or any instance holding live data. |
| FR-5.3 | The test MUST assert pre-run that the target instance is empty (`SELECT count() = 0` from `usage_log`, `request_log`, `billing_ledger`) and MUST NOT bind the dev stack's published port 8123 (use an ephemeral loopback port). |
| FR-5.4 | The test MUST tear down the ephemeral instance and remove the SQLite copy afterwards, leaving the dev environment untouched. |

## 4. Non-Functional Requirements

| ID | Requirement |
|----|-------------|
| NFR-1 | Runtime MUST complete the full ~61k-row backfill in minutes (streaming sqlite3 cursor → batched HTTP inserts; no full in-memory row set). |
| NFR-2 | The script MUST be plain bash + `sqlite3` + `curl` + `jq` + `md5sum`/`openssl`, matching `res/scripts/` conventions (see `dedupe-model-history.sh`). |
| NFR-3 | ClickHouse endpoint MUST be configurable (`CLICKHOUSE_URL`, default `http://localhost:8123`), database via `DATABASE` (default `llm_gateway`). |
| NFR-4 | Live-gateway compatibility: migrator rows MUST NOT use `event_id` formats produced by Vector (`route_id_seconds`) or sse-usage, and MUST NOT collide with APISIX `request_id` values. |

## 5. Acceptance Criteria

| ID | Criterion |
|----|-----------|
| AC-1 | Running the migrator twice inserts each row exactly once (second run reports 0 inserts). |
| AC-2 | A planted duplicate (identical natural key, different `message.id`) in a fixture database is collapsed to one row. |
| AC-3 | `usage_log`/`request_log` counts and per-field values for a fixture database match the SPEC field map exactly. |
| AC-4 | Grafana cost panels show historical totals increasing by the migrated sum after one run. |
| AC-5 | A full-database rehearsal (FR-5: SQLite copy + fresh isolated ClickHouse) completes with dry-run counts matching insert counts, zero errors, and an idempotent second pass. |

## 6. Implementation Status

| Item | Status | Evidence |
|------|--------|----------|
| `res/scripts/migrate-opencode-stats.sh` | Implemented | fixture pass 69/69 (2026-08-28, incl. models.dev pricing, shadow map, `--force` gate) |
| Fixture test | Implemented | [`tests/test_migrate_opencode_stats.sh`](../../tests/test_migrate_opencode_stats.sh): isolation (FR-5), field map (AC-3), idempotency (AC-1/2), pricing/shadow, rerun gate (FR-4.6), rehearsal (AC-5) |
| ClickHouse schema | Already sufficient | [`conf/clickhouse-init.sql`](../../conf/clickhouse-init.sql) needs no change |
| Production run against dev ClickHouse | Complete | 62,157 rows re-migrated (2026-08-28) via the FR-4.6 reset procedure with computed pricing: cost_source upstream $999.30 (34,329 rows) + computed $893.98 (21,291 rows) + unknown 6,535 (free-tier/unlisted); second `--force` pass idempotent; plain rerun aborts at the gate; backups under `backups/2026-08-28-pre-pricing-rerun/`, `-pricing-rerun/` |
