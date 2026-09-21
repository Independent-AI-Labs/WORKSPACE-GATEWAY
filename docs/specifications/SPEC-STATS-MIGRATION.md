# SPEC-STATS-MIGRATION: opencode SQLite Stats Migrator Implementation

**Date:** 2026-08-28
**Status:** Implemented
**Type:** Specification
**Requirements:** [REQ-STATS-MIGRATION](../requirements/REQ-STATS-MIGRATION.md)

> Specifies `res/scripts/migrate-opencode-stats.sh`:
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
- `time.created` range: 2026-06-30 → 2026-08-28 (nothing near 13 months old)
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
- TTL: none (superseded 2026-09-20 by REQ-SECURITY-HARDENING FR-4: tiered
  compression, indefinite retention; the migrator's "older than 13 months"
  classification remains as a reporting bucket only).
- `tokens.cache.write` maps to `usage_log.cache_write_tokens` (live path
  stores it too since REQ migration `000012`); `cached_tokens` = cache read.

## 3. Field Maps

### 3.1 `message` → `usage_log`

| usage_log column | Source expression | Notes |
|------------------|-------------------|-------|
| `event_id` | `'ocm_' ‖ message.id` | deterministic; idempotency key |
| `request_id` | `message.id` | joins to request_log row |
| `model` | `canonical(json_extract(data,'$.modelID'))` | see §4 |
| `model_raw` | `json_extract(data,'$.modelID')` | verbatim |
| `prompt_tokens` | `tokens.input + tokens.cache.read + tokens.cache.write` | upstream convention (sse_usage_lib.lua): prompt INCLUDES cache read and write; opencode stores them disjoint |
| `completion_tokens` | `tokens.output + tokens.reasoning` | upstream convention: completion INCLUDES reasoning; opencode stores them disjoint |
| `reasoning_tokens` | `tokens.reasoning` | |
| `cached_tokens` | `tokens.cache.read` | |
| `cache_write_tokens` | `tokens.cache.write` | |
| `total_tokens` | `prompt_tokens + completion_tokens` | live default convention |
| `key_id`, `api_key_id` | `''` | no SQLite source |
| `aborted` | mapped from `message.data.error.name`: `MessageAbortedError` → `1` (client cancel), `APIError`/`UnknownError` → `2` (provider abort), absent → `0` (completed). Source: `session/message-v2.ts` `fromError()` persists terminal outcomes on the assistant message | terminal outcome per generation; note the gateway logs per-attempt stream deaths, so gateway-era abort rates count attempts while migrated rows count outcomes |
| `is_stream` | `1` | opencode always streams |
| `cost` | catalog-priced per §4.1 (provider `pricing.overrides`, else models.dev) | billed USD; never the opencode-recorded cost |
| `reported_cost` | `json_extract(data,'$.cost')` | upstream/opencode-recorded cost, persisted as metadata only; never billed |
| `cost_source` | `'provider_override'` when a `pricing.overrides` rate applied, `'models_dev'` when priced via models.dev in §4.1, else `'unknown'` | billed provenance; mirrors `resolve_cost` semantics |
| `provider_id` | `resolve_provider(json_extract(data,'$.providerID'))`: `cost_calc.PROVIDER_ALIASES` remap, otherwise verbatim (no other provider) | aligns historical ids with canonical gateway ids |
| `duration_ms` | `time.completed − time_created` when within `[0, 1h)`, else `0` | per-generation wall time; mirrors gateway sse-usage `duration_ms` |
| `ttft_content_ms` | `min(part.time_created WHERE part.type != 'reasoning') − time_created`, clamped `[0, 1h)`, else `0` | first visible (text/tool) output; mirrors gateway `ttft_content_ms` |
| `pricing_source`, `pricing_snapshot` | `''` | no pricing catalog at migration time |
| `timestamp` | `datetime(time_created/1000, 'unixepoch')` → ms precision | `time_created` is ms epoch |

### 3.2 `message` + `session` → `request_log`

| request_log column | Source expression | Notes |
|---------------------|-------------------|-------|
| `event_id` | `'ocr_' ‖ message.id` | deterministic |
| `provider` | resolved `provider_id` (same alias remap as usage_log) | canonical |
| `model` / `model_raw` | same as usage_log | real |
| `method` | `'POST'` | synthetic (constant) |
| `uri` | `gateway_route(provider_id) ‖ '/chat/completions'`, else `'/v1/chat/completions'` | synthetic: the declared gateway route from `conf/providers/*.yaml` |
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
| `upstream_response_time_s` | `duration_ms / 1000` (3 decimals) | lights SPEC-DASHBOARD p10 (avg response time) for migrated models |
| `client_type` | `'migrated'` | marker so ops dashboards can filter backfilled rows |
| `req_body` | synthesized `{"model": <canonical>, "messages": [...]}`: one empty-content `assistant` message per prior assistant turn in the session (capped at 200; gives the cruncher followup detection), the last user `text` part before the request (single-line, capped 64 KiB; gives profanity/frustration classification), and one `assistant` message per prior part carrying a guard-block or permission-rejection marker string (total capped 128 KiB; gives the cruncher's marker counts) | the usefulness cruncher reads only roles, the last user content, and marker substrings, so this minimal body reproduces its full signal surface without storing whole conversations |
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

## 4.1 Billed Pricing Resolution (all rows)

Billed cost is resolved for **every** row, exactly as the live path does:
provider `pricing.overrides` first, else models.dev. models.dev is a
pricing/metadata **registry**, not a provider. Source: **models.dev**
(`MODELS_DEV_URL`, default `https://models.dev/api.json`; `--pricing-file
<json>` for offline/test runs) - the same registry the gateway uses; every
gateway provider declares `pricing.source.type: models_dev` and a
`pricing.source.provider` namespace in `conf/providers/*.yaml` (e.g.
kimi→`moonshotai`, opencode-go→`opencode`, zai→`zai`). Flattened to:

```
models_dev_provider \t model(lower) \t input \t output \t cache_read \t cache_write \t reasoning
```

(USD per 1M tokens, base tier only, matching `cost_calc.compute_cost`.)

Provider resolution is **explicit**, one step, no second lookup:

1. Apply `cost_calc.PROVIDER_ALIASES` to the historical `providerID`.
2. If the result is a gateway id (present in `conf/providers/*.yaml`), the
   models.dev namespace is that id's declared `pricing.source.provider`;
   it is empty when `pricing.source.type` is not `models_dev` (e.g.
   llamafile).
3. Otherwise, an explicit direct-provider equivalence applies
   (`zai-coding-plan` → `zai`: the flat-fee plan publishes only zero rates
   on models.dev, so it is priced at the PAYG-equivalent namespace), and
   failing that the historical `providerID` is used as the models.dev
   namespace directly (opencode's direct providers, namely `openai`,
   `opencode-go`, `opencode`, and `amazon-bedrock`, are used as models.dev
   namespaces).

The lookup key is `models_dev_provider : canonical(modelID)`. A rate that
models.dev omits is applied the same way the live path applies it: a
missing/zero `reasoning` rate bills reasoning at the `output` rate
(`provider_sync_pricing` publishes a reasoning rate only when the catalog
has one, so `compute_cost` falls through to output), while `cache_read` and
`cache_write` are published as `0` and billed as `0`. A row whose resolved
models.dev namespace is empty, or whose model has no models.dev cost, stays
unpriced. `workspace-gateway` is the one historical id with no
models.dev namespace (99 rows) and is written `cost=0`,
`cost_source='unknown'` explicitly. A rate row is only used when its input
rate is > 0 (a malformed all-zero row must never zero out token cost,
mirroring `recalc.lua` `build_prices`).

Computed cost (mirrors `cost_calc.compute_cost`):

```
input_uncached      = max(prompt − cached − cache_write, 0)
output_non_reasoning = completion − reasoning  (completion when reasoning exceeds it)
cost = ( input_uncached      * input_rate
       + output_non_reasoning * output_rate
       + cached               * cache_read_rate
       + cache_write          * cache_write_rate
       + reasoning            * reasoning_rate ) / 1e6
```

Result: `cost_source='models_dev'` (or `'provider_override'` when a
`pricing.overrides` rate applied). Rows with no pricing hit keep cost 0,
`cost_source='unknown'` (free-tier models such as `big-pickle`/`*-free`,
`workspace-gateway`). The opencode-recorded cost is written to
`reported_cost` regardless of whether billing resolved.

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

**On-demand hashing.** The hash only distinguishes rows that already share
the natural key `(session_id, providerID, modelID, time_created)`. Extraction
therefore collects those keys across ALL sources first and computes MD5 only
for messages inside a colliding group; every other message gets an empty
hash. The kept-row set is identical, but the per-message `md5sum` forks that
dominated the run time (≈60k process spawns, ≈4.5 min) collapse to the few
real collisions. On healthy data that set is empty.

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

1. **Registry + pricing**: model alias map from `conf/model-registry.yaml`;
   provider alias map from `cost_calc.lua`; gateway provider declarations
   (id → route, models.dev namespace) from `conf/providers/*.yaml`; pricing
   TSV from models.dev per §4.1 (or `--pricing-file`).
2. **Extract**: first pass per source db runs the `message`→`session` query
   plus the role/marker/first-part queries; the §5.1 natural keys are then
   collected across all sources. A second pass streams each message's ordered
   `part` rows (hex-encoded `type:text`) and folds them into the
   `content_hash` via `md5sum` **only for messages in a colliding natural-key
   group** (§5.1 on-demand hashing); every other message gets an empty hash.
   Read-only URI `?mode=ro`; sources missing on disk are skipped with a
   warning (FR-1.4 no-op, not error). Each stage prints `[TIME] <stage> Nms`
   to stderr so regressions on the multi-GB real DB stay visible.
3. **Dedup**: sort by natural key then `message.id`; keep first of each
   natural key across ALL sources combined. Report `source_duplicates`.
4. **Filter**: `--dry-run` stops here (after materialization, so the diff
    sees final fields) and prints: rows to insert per table, source
    duplicates collapsed, older-than-13-months count
    (`time_created < now − 13 months`; reporting bucket only), pricing
    coverage of cost-0 rows, and, when ClickHouse is reachable,
    already-present counts plus a **source-vs-target diff**
    (`missing`/`differing`/`extra` over `event_id`, a per-field difference
    histogram, and up to five sample differing rows). This surfaces exactly
    which historical rows a fresh (aligned) run would add or change, for example
    raw-vs-canonical provider ids, cost/`cost_source` shifts, dropped
    cache-write tokens, constant uri.
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

After the insert, run `res/scripts/recalc-costs.sh --apply --all
--confirm-all` (SPEC-COST-CALC §6). The migration backfills history from
models.dev; the recalc is the authoritative pass over the live gateway
catalog and the only pass that touches pre-existing `relay-*` rows, so
migration → recalc → recalc-dry-run (0 corrections) is the converged
sequence.

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
| cost = 0 (27,725 rows) | Priced provider-scoped from models.dev per §4.1 (`cost_source='models_dev'`, or `'provider_override'` when an override applied); rows whose resolved models.dev namespace/model has no rate (including `workspace-gateway`) keep cost 0, `cost_source='unknown'` (never fabricated) |
| `tokens.cache.write` | Migrated to `cache_write_tokens` and included in `prompt_tokens`/cost (live path stores it since `000012`) |
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
2. Assert dry-run counts (source_duplicates=1, insert=2, orphan=1), the
   provider-scoped models.dev pricing coverage, and the source-vs-target
   missing/differing/extra diff line
   (`[DRY-RUN] diff vs ClickHouse: missing=N differing=N extra=N`).
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
| `res/scripts/migrate-opencode-stats.sh` | Complete | fixture test 88/88 pass (2026-09-21, incl. §4.1 provider-scoped models.dev pricing, provider canonicalization, `cache_write_tokens`, gateway-route `uri`, `--force` gate, dry-run diff) |
| `tests/test_migrate_opencode_stats.sh` | Complete | fixture + isolation + backup + idempotency + models.dev pricing + provider alias + rerun gate + `--full` rehearsal 88/88 pass (2026-09-21) |
| Source probes | Complete | §1 (run 2026-08-28 against live opencode.db) |
| Schema fit | Verified | all §3 destination columns exist in `conf/clickhouse-init.sql` |
| Production run against dev ClickHouse | Complete | re-run with computed pricing (2026-08-28) via the §6 step-5 reset procedure: 62,157 rows; cost_source upstream $999.30 / computed $893.98 / unknown 6,535 rows; second `--force` pass idempotent, gate blocks plain reruns; backups at `backups/2026-08-28-pre-migration/`, `-broken-migrated-rows/`, `-pre-repair/`, `-pre-pricing-rerun/`, `-pricing-rerun/` |
| Production re-run, models.dev alignment (2026-09-21) | Complete | reset (§6 step 5) then `--force` insert: 75,259 usage_log + 75,259 request_log rows; `cost_source` upstream 45,304 / $1,813.23, computed 26,566 / $1,083.17, unknown 3,389; follow-up `recalc-costs.sh --apply --all --confirm-all` (`run-20260921095045-3486843`, backup `pre-recalc-20260921095045-3486843`) corrected 22,920 rows (22,203 live `relay-*` + 717 migrated) in 8 grouped `UPDATE`s, re-run a converged no-op; final dry-run `missing=0 differing=717 extra=0` (717 = sub-1e-7 Float64/Lua cost rounding on recalc-owned rows); backups at `backups/2026-09-21-pre-aligned-remigrate/`, `backups/2026-09-21-aligned-remigrate/` |
