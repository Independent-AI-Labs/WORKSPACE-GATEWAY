# SPEC-STATS-MIGRATION: opencode SQLite Stats Migrator Implementation

**Date:** 2026-08-28
**Status:** Draft
**Type:** Specification
**Requirements:** [REQ-STATS-MIGRATION](../requirements/REQ-STATS-MIGRATION.md)

> Specifies `res/scripts/migrate-opencode-stats.sh` (not yet implemented):
> a read-only, idempotent bash migrator from the opencode SQLite client
> database into `llm_gateway.usage_log` and `llm_gateway.request_log`.
> All source facts below were probed against the live 10 GiB
> `opencode.db` on 2026-08-28.

---

**Cross-references:**
- [REQ-STATS-MIGRATION](../requirements/REQ-STATS-MIGRATION.md): requirements
- [`conf/clickhouse-init.sql`](../../conf/clickhouse-init.sql): destination schema (ground truth)
- [`conf/vector.toml`](../../conf/vector.toml): live model canonicalization mirrored by the migrator
- [`conf/model-registry.yaml`](../../conf/model-registry.yaml): canonical alias map (single source of truth)
- [`plugins/custom/sse_usage_lib.lua`](../../plugins/custom/sse_usage_lib.lua): live `total_tokens` default convention
- [`res/scripts/dedupe-model-history.sh`](../../res/scripts/dedupe-model-history.sh): `ch()` curl helper pattern reused
- [TELEMETRY-AND-SCHEMA](../architecture/TELEMETRY-AND-SCHEMA.md): write-path overview

---

## 1. Source Ground Truth (probed 2026-08-28)

Database `~/.local/share/opencode/opencode.db` (10 GiB, WAL, live).
`opencode-dev.db` (10 MB) has the identical schema of the tables below and
0 message rows at probe time; it is still scanned for future-proofing.
All counts are a point-in-time snapshot of a live database and drift as
opencode runs; the migrator must never hardcode them.

| Table | Rows | Relevant columns |
|-------|------|------------------|
| `session` | 830 | `id, project_id, parent_id (NULL on 169), version (e.g. "1.17.11"), time_created` |
| `message` | 68,073 (61,147 assistant / 7,008 user) | `id ("msg_" + ULID), session_id, time_created (ms), data (JSON)` |
| `part` | 281,107 | `id (ULID), message_id, session_id, data (JSON)` |
| `project` | 9 | `id` (join validation only) |

`message.data` JSON for assistant rows (field coverage 61,147/61,147):

```json
{"parentID":"msg_...", "role":"assistant", "mode":"plan", "agent":"plan",
 "variant":"low", "cost":0.0123, "modelID":"glm-5.3",
 "providerID":"zai-coding-plan",
 "tokens":{"input":1,"output":1,"reasoning":0,"cache":{"read":0,"write":0}},
 "time":{"created":1787917493803}}
```

- `agent` values: `build` (46,202), `plan` (5,526), `general` (5,427),
  `explore` (3,515), `compaction` (479)
- `cost > 0` on 33,422 assistant rows; 0 on 27,725
- `time.created` range: 2026-06-30 → 2026-08-28 (nothing near the 13-month TTL)
- Provider/model distribution (top): `workspace-gw-kimi/k3` (12,311),
  `opencode-go/glm-5.1` (11,032), `openai/gpt-5.6-luna` (8,187),
  `workspace-gw-own/glm-5.2` (8,182), `zai-coding-plan/glm-5.3` (3,623),
  incl. odd raws like `/zip/MiniCPM5-1B-Q8_0.gguf`
- User rows have NO `tokens` object (0/7,008) → only assistant rows migrate

Part `data.type` distribution: `step-start` 60,244, `step-finish` 59,153,
`tool` 85,699, `reasoning` 46,293, `text` 28,010, `patch` 1,259,
`compaction` 471, `file` 20.

`session.model` is a JSON blob (`{"id","providerID","variant"}`) and is
NOT used: per-message `modelID`/`providerID` are authoritative. `session.agent`
is NULL on 1 row; `session.version` never empty.

## 2. Destination Ground Truth

`llm_gateway.usage_log` and `llm_gateway.request_log` as defined in
[`conf/clickhouse-init.sql`](../../conf/clickhouse-init.sql). Key facts
driving this design:

- `billing_ledger_mv` fires on every `usage_log` INSERT → historical cost
  enters `billing_ledger` automatically with `provider='opencode'`.
- Live `event_id`s: Vector writes `route_id + '_' + floor(start_time_seconds)`
  into `request_log`; sse-usage writes its own `event_id` into `usage_log`.
  Prefixes `ocm_` / `ocr_` cannot collide.
- Live `request_id`s are APISIX request-ids; SQLite `msg_...` ids cannot collide.
- TTL 13 months on both tables (currently moot: oldest data is 2 months).
- `tokens.cache.write` has no destination column (live path also drops it;
  `cached_tokens` = cache read). Known, accepted loss.

## 3. Field Maps

### 3.1 `message` → `usage_log`

| usage_log column | Source expression | Notes |
|------------------|-------------------|-------|
| `event_id` | `'ocm_' ‖ message.id` | deterministic; idempotency key |
| `request_id` | `message.id` | joins to request_log row |
| `model` | `canonical(json_extract(data,'$.modelID'))` | see §4 |
| `model_raw` | `json_extract(data,'$.modelID')` | verbatim |
| `prompt_tokens` | `tokens.input + tokens.cache.read` | upstream convention (sse_usage_lib.lua): prompt INCLUDES cached; opencode stores them disjoint |
| `completion_tokens` | `tokens.output + tokens.reasoning` | upstream convention: completion INCLUDES reasoning; opencode stores them disjoint |
| `reasoning_tokens` | `tokens.reasoning` | |
| `cached_tokens` | `tokens.cache.read` | |
| `total_tokens` | `prompt_tokens + completion_tokens` | live default convention |
| `key_id`, `api_key_id` | `''` | no SQLite source |
| `aborted` | `0` | client DB records no abort state |
| `is_stream` | `1` | opencode always streams |
| `cost` | `json_extract(data,'$.cost')` when > 0, else models.dev-priced per §4.1 | USD |
| `cost_source` | `'upstream'` if source cost > 0, `'computed'` if priced via §4.1, else `'unknown'` | mirrors `resolve_cost` semantics |
| `provider_id` | `json_extract(data,'$.providerID')` | |
| `pricing_source`, `pricing_snapshot` | `''` | no pricing catalog at migration time |
| `timestamp` | `datetime(time_created/1000, 'unixepoch')` → ms precision | `time_created` is ms epoch |

### 3.2 `message` + `session` → `request_log`

| request_log column | Source expression | Notes |
|---------------------|-------------------|-------|
| `event_id` | `'ocr_' ‖ message.id` | deterministic |
| `provider` | `message.providerID` | real |
| `model` / `model_raw` | same as usage_log | real |
| `method` | `'POST'` | synthetic (constant) |
| `uri` | `'/v1/chat/completions'` | synthetic (constant) |
| `status` | `200` | synthetic (constant) |
| `stream` | `true` | matches opencode behavior |
| `session_id` | `session.id` | real |
| `project_id` | `session.project_id` | real |
| `parent_session_id` | `session.parent_id` (or `''`) | real |
| `agent_name` | `json_extract(message.data,'$.agent')` | real |
| `opencode_version` | `session.version` | real |
| `user_agent` | `'opencode/' ‖ session.version` | derived, real version |
| `request_id` | `message.id` | join key |
| `request_size` | session content bytes of `text`/`reasoning` parts (all roles) with `part.time_created < message.time_created`, excluding replay-duplicate messages that lost the §5.1 dedup | pseudo-size from real chunks: the context sent upstream |
| `response_size` | byte length of the message's own `text`/`reasoning` part texts | pseudo-size from real chunks |
| `client_type` | `'migrated'` | marker so ops dashboards can filter backfilled rows |
| `upstream_response_time_s`, `client_ip` | `0` / `0.0.0.0` | synthetic defaults (no source) |
| `api_key_id`, `tenant_id`, `user_id`, `key_id` | `''` | no source |
| `req_body`, `resp_body` | `''` | content is NOT migrated |
| `redact_active`, `redact_token_count` | `false` / `0` | |
| `timestamp` | same as usage_log row | |

## 4. Model Canonicalization

Identical algorithm to the generated block in
[`conf/vector.toml`](../../conf/vector.toml) (mirror of
`model_registry.lua M.canonical`), applied to the SQLite `modelID`:

```
m   = lower(modelID)
m   = alias_map[m] if present
else m = substring after last '/' of m, then alias_map lookup again
```

Alias map is read from [`conf/model-registry.yaml`](../../conf/model-registry.yaml)
at run time (jq/yaml_helpers), never hardcoded. Probed effects:
`k3`→`kimi-k3`, `kimi-for-coding`→`kimi-k2.7-code`,
`/zip/MiniCPM5-1B-Q8_0.gguf`→`minicpm5-1b-q8_0.gguf`,
`zai.glm-5` (dot-form bedrock id)→`glm-5`; `glm-5.3`,
`big-pickle`, `gpt-5.6-luna` pass through lowercased.

## 4.1 Pricing Resolution (cost = 0 rows)

Catalog: models.dev (`MODELS_DEV_URL`, or `--pricing-file`), flattened to
`provider \t model(lower) \t input \t output \t cache_read` (USD per 1M
tokens, base tier only; tiered overrides ignored, matching `cost_calc.lua`).

Lookup order for a row with source cost 0, first hit with any rate > 0 wins:

1. `providerID : lower(modelID)`
2. `providerID : canonical(modelID)`
3. `shadow(providerID) : lower(modelID)` and `shadow(providerID) : canonical(modelID)`

Shadow map: `zai-coding-plan`→`zai`. Subscription-plan providers publish
all-zero rates on models.dev; the shadow prices those rows at the
PAYG-equivalent provider so cost dashboards reflect economic value.

Computed cost (mirrors `cost_calc.lua` formula):

```
cost = ( tokens.input        * input_rate
       + tokens.output       * output_rate
       + tokens.cache.read   * cache_read_rate
       + tokens.reasoning    * output_rate ) / 1e6
```

Result: `cost_source='computed'`. Rows with no pricing hit keep cost 0,
`cost_source='unknown'` (free-tier models such as `big-pickle`/`*-free`,
unlisted providers).

## 5. Duplicate Detection

### 5.1 Source-side content dedup (extraction time)

Natural key:

```
( session_id,
  role,                 -- always 'assistant' after FR-1.3 filter
  providerID,
  modelID,
  time_created,
  content_hash )
```

`content_hash` = MD5 of the concatenation, over `part` rows of the message
ordered by `part.id` (ULID ⇒ chronological), filtered to
`json_extract(data,'$.type') IN ('text','reasoning')`, of the hex encoding
of `type ‖ ':' ‖ json_extract(data,'$.text')`, parts joined by the hex of
`'\n'` (`0A`). Hex-encoding makes the concatenation unambiguous and
injection-safe across arbitrary part content.

Rationale: identical logical turns replayed/imported (e.g. dev-db copies)
share session, model, millisecond timestamp and content; transient parts
(`step-*`, `tool`, `patch`) vary across replays and MUST NOT break the key.
Within a collision group keep `min(message.id)`.

### 5.2 ClickHouse-side idempotency (insert time)

Per batch, before insert:

```sql
SELECT event_id FROM llm_gateway.usage_log WHERE event_id IN (batch ids)
SELECT event_id FROM llm_gateway.request_log WHERE event_id IN (batch ids)
```

Present ids are dropped from the batch (counted as `skipped_existing`).
Deterministic prefixes make this exact for re-runs and impossible to
collide with live rows.

## 6. Script Design

`res/scripts/migrate-opencode-stats.sh`: bash, `set -euo pipefail`,
reusing the `ch()` curl-POST helper shape from
`dedupe-model-history.sh`.

```
Usage: migrate-opencode-stats.sh [--dry-run] [--force] [--clickhouse-url <url>] [--backup-dir <dir>] [--pricing-file <models.dev.json>]
Env:   OPENCODE_DBS   colon-separated sqlite paths
                    (default ~/.local/share/opencode/opencode.db:opencode-dev.db)
       CLICKHOUSE_URL default http://localhost:8123
       DATABASE       default llm_gateway
       BATCH_SIZE     default 5000
       MODELS_DEV_URL default https://models.dev/api.json
```

Pipeline (single streaming pass per source, spills nothing to disk except
one dedup stage file under mktemp):

1. **Registry + pricing**: alias map from `conf/model-registry.yaml`;
   pricing TSV from models.dev per §4.1 (or `--pricing-file`).
2. **Extract**: one `sqlite3` query per source db streaming the message's
   ordered `part` rows (hex-encoded `type:text`) which awk folds into the
   §5.1 `content_hash` via `md5sum`, plus a second query joining
   `message`→`session` for the message/session fields, both emitting TSV.
   Read-only URI `?mode=ro`; sources missing on disk are skipped with a
   warning (FR-1.4 no-op, not error).
3. **Dedup**: sort by natural key then `message.id`; keep first of each
   natural key across ALL sources combined. Report `source_duplicates`.
4. **Filter**: `--dry-run` stops here and prints: rows to insert per table,
   source duplicates collapsed, TTL-expired count
   (`time_created < now − 13 months`), pricing coverage of cost-0 rows,
   and, when ClickHouse is reachable, already-present counts.
5. **Rerun gate**: if `usage_log` already holds any `ocm_%` row, abort
   unless `--force` (FR-4.6; stable event ids would otherwise keep
   stale cost/mapping values without any signal). Reset procedure:

   ```bash
   # 1. fresh backup (previous --backup-dir dumps suffice if current)
   # 2. delete migrated rows and wait for the mutations:
   curl "$CLICKHOUSE_URL/" --data-binary \
     "ALTER TABLE llm_gateway.usage_log DELETE WHERE event_id LIKE 'ocm_%' SETTINGS mutations_sync=2"
   curl "$CLICKHOUSE_URL/" --data-binary \
     "ALTER TABLE llm_gateway.request_log DELETE WHERE event_id LIKE 'ocr_%' SETTINGS mutations_sync=2"
   curl "$CLICKHOUSE_URL/" --data-binary \
     "ALTER TABLE llm_gateway.billing_ledger DELETE WHERE event_id LIKE 'ocm_%' SETTINGS mutations_sync=2"
   # 3. verify all three counts are 0, then:
   res/scripts/migrate-opencode-stats.sh --force --backup-dir backups/<date>-rerun
   ```
6. **Backup** (`--backup-dir`): before any insert, `FORMAT Native` dump of
   `usage_log`, `request_log`, `billing_ledger` plus `manifest.txt`
   (row counts + `sum(cityHash64(*))` per table). Mandatory for the
   production run (FR-4.5).
7. **Pre-flight check + insert**: per batch of `BATCH_SIZE`: fetch existing
   event_ids, drop them, then two `INSERT INTO ... FORMAT JSONEachRow`
   POSTs (usage_log first so the MV fires after its request_log twin is
   trivially cheap; order is not semantic). Any HTTP error aborts (FR-4.2).

Runtime target: ~61k rows ≈ 13 batches, minutes (NFR-1).

## 7. Rollback

Not automated (FR-4.3). Manual:

```sql
ALTER TABLE llm_gateway.usage_log  DELETE WHERE event_id LIKE 'ocm_%';
ALTER TABLE llm_gateway.request_log DELETE WHERE event_id LIKE 'ocr_%';
ALTER TABLE llm_gateway.billing_ledger DELETE WHERE event_id LIKE 'ocm_%';
```

(`billing_ledger_mv` copies the event_id, so ledger rows are removable by
the same prefix.)

## 8. Edge Cases & Decisions

| Case | Decision |
|------|----------|
| cost = 0 (27,725 rows) | Priced from models.dev per §4.1 (`cost_source='computed'`); subscription-plan rows via shadow map; still-unpriced rows keep cost 0, `cost_source='unknown'` (never fabricated) |
| `tokens.cache.write` | Dropped (no destination column; live path drops it too) |
| `session.agent` NULL (1 session) | `agent_name` from message-level `agent` (present on all assistant rows at probe time); otherwise `session.agent`, else `''` |
| Orphan `message.session_id` with no `session` row | 0 orphans at probe time; the inner `message`→`session` join drops any such row (session dims unavailable) |
| DB busy / WAL lock | `?mode=ro` + `busy_timeout` retry; never blocks opencode |
| Rows older than TTL | Inserted anyway; ClickHouse expires them; dry-run reports the count up front |
| Live-gateway overlap | Impossible by construction: distinct `event_id` prefixes and `request_id` namespaces; live and migrated rows are different events |
| Grafana/Prometheus | No change (see REQ §1.2) |

## 9. Test Plan

`tests/test_migrate_opencode_stats.sh` (fixture-based). Two mandatory
isolation invariants per REQ FR-5: the SQLite source is always a COPY, and
the ClickHouse target is always a brand-new instance provisioned for the
test; the dev stack is never touched.

### 9.1 Isolation setup (every run)

1. **SQLite copy**: `sqlite3 "$OPENCODE_LIVE_DB" ".backup '$TMPDIR/mig-test.db"`
   (online, WAL-safe; never `cp` the live files). Assert afterwards that
   no `$TMPDIR/mig-test.db-wal` / `-shm` exist (byte-stable copy). Fixture
   rows (below) are INSERTed into this copy, not into any real database.
2. **Fresh ClickHouse**: ephemeral podman container, unique name, fresh
   anonymous volume, `conf/clickhouse-init.sql` bind-mounted to
   `/docker-entrypoint-initdb.d/init.sql:ro` (same pattern as
   `tests/docker-compose.test.yml` `clickhouse` service), HTTP published on
   an ephemeral loopback port (`-p 127.0.0.1::8123`), NOT dev's 8123.
3. **Emptiness assertion**: pre-run `SELECT count() FROM llm_gateway.usage_log`
   (and `request_log`, `billing_ledger`) MUST return 0; abort otherwise
   (guards against accidentally pointing at a non-fresh instance).
4. **Teardown**: `podman rm -f` the container (anonymous volume dies with
   it), `rm` the SQLite copy. Runs in a trap so failures still clean up.

### 9.2 Functional stages

1. Into the SQLite copy, insert: 3 assistant messages (one planted
   natural-key duplicate), 1 user message, 1 orphan message, 1 session.
2. Assert dry-run counts (source_duplicates=1, insert=2, orphan=1).
3. Run against the fresh ClickHouse; assert `usage_log`/`request_log` row
   fields exactly per §3 map (jq over `FORMAT JSONEachRow` SELECT), and
   `billing_ledger` gained matching rows via the MV.
4. Run again; assert 0 inserts (idempotency, AC-1/AC-2/AC-3).

### 9.3 Full-database rehearsal (AC-5)

Opt-in stage (`--full`, skipped when the live DB is absent or smaller than
a threshold): repeat §9.1 with an unmodified `.backup` copy of the entire
`opencode.db`, migrate into a second fresh ClickHouse, and assert
(a) dry-run insert counts equal post-run `usage_log`/`request_log` counts,
(b) exit 0, (c) second pass inserts 0 rows. This is the pre-production
rehearsal for the real run against dev.

## 10. Implementation Status

| Item | Status | Evidence |
|------|--------|----------|
| `res/scripts/migrate-opencode-stats.sh` | Complete | fixture test 69/69 pass (2026-08-28, incl. §4.1 pricing, shadow map, `--force` gate) |
| `tests/test_migrate_opencode_stats.sh` | Complete | fixture + isolation + backup + idempotency + pricing/shadow + rerun gate + `--full` rehearsal 69/69 pass; rehearsal migrated 61,496 rows, second pass inserted 0 (2026-08-28) |
| Source probes | Complete | §1 (run 2026-08-28 against live opencode.db) |
| Schema fit | Verified | all §3 destination columns exist in `conf/clickhouse-init.sql` |
| Production run against dev ClickHouse | Re-run pending | first run 61,645 rows (2026-08-28, after token-semantics repair); re-run with computed pricing via the §6 step-5 reset procedure; backups at `backups/2026-08-28-pre-migration/`, `-broken-migrated-rows/`, `-pre-repair/` |
