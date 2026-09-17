# SPEC-USEFULNESS-TELEMETRY: Practical-Usefulness Metrics Implementation

**Date:** 2026-09-16
**Status:** Active
**Type:** Specification
**Requirements:** [REQ-USEFULNESS-TELEMETRY](../requirements/REQ-USEFULNESS-TELEMETRY.md)

> Implementation design for TTFT/duration capture, the idempotent batch
> rejection-language cruncher (Lua core + shell orchestrator), dictionary
> handling, the `request_signals` table, and the `gateway-model-experience` / `gateway-model-performance`
> dashboard. All components below are implemented; see §8.

---

**Cross-references:**
- [REQ-USEFULNESS-TELEMETRY](../requirements/REQ-USEFULNESS-TELEMETRY.md): requirements owned by this spec
- [SPEC-BILLING-TELEMETRY.md](SPEC-BILLING-TELEMETRY.md): existing sse-usage → usage_log write path being extended
- [SPEC-DASHBOARD.md](SPEC-DASHBOARD.md): dashboard conventions this dashboard follows
- `res/scripts/backfill-reasoning-tokens.sh`: the batch-script precedent mirrored here

---

## 1. Architecture

```
request path (Lua, µs-scale work only)
  sse-usage.lua ── body_filter: stamp ttft_first_byte_ms (first non-empty chunk)
                 ├─ sse_usage_lib: flag first content-bearing SSE event
                 │                → stamp ttft_content_ms
                 └─ log phase: duration_ms → usage_log (new cols, migration 000008)

batch (periodic, idempotent; no request-path involvement)
  crunch-usefulness.sh
    1. SELECT aligned window from request_log
       (ClickHouse JSON-extracts last user msg + is_followup → TSV)
    2. podman exec apisix luajit cruncher.lua < tsv > tsv'
       (fuzzy profanity + phrase matching, dedup, canonicalize)
    3. DELETE window FROM request_signals; INSERT tsv'
   dictionaries: conf/profanity/{en.txt, frustration-phrases.txt,
   vader-negative.txt, fuzzy-blocklist.txt} (vendored; make
   gw-update-dictionaries refreshes, blocklist auto-generated)

dashboards
  gateway-model-{experience,performance}.json → usage_log (speed/abort/cost) +
  request_signals (rejection): never scans req_body at refresh
```

Rationale: TTFT is only observable in the gateway (C-5: no Prometheus
first-byte metric); rejection language is derivable from stored `req_body`
history, so it is crunched offline: 13 months of backfill in one run, zero
per-refresh body scanning.

## 2. TTFT and Duration Capture

### 2.1 `plugins/custom/sse_usage_lib.lua`

`scan_sse_for_usage(complete)` currently returns `usage, model, done, cost`.
Extended contract: `usage, model, done, cost, has_content` where `has_content`
is true when the scanned batch contains any event with non-empty textual
delta: OpenAI chat format `choices[0].delta.{content,reasoning_content}`,
Responses-API frames with type `response.output_text.delta` (or
`reasoning_text.delta`) carrying non-empty text. Boolean-or across the batch;
the caller stamps time once. Pure string scanning, no new allocations beyond
existing per-event parsing.

### 2.2 `plugins/custom/sse-usage.lua`

```lua
-- body_filter, on every non-empty chunk, before buffering:
if chunk and chunk ~= "" and not ctx.sse_first_byte_ms then
    ctx.sse_first_byte_ms = math.floor((ngx.now() - ngx.req.start_time()) * 1000)
end
-- wherever a scan returns has_content and not ctx.sse_content_ms:
    ctx.sse_content_ms = math.floor((ngx.now() - ngx.req.start_time()) * 1000)

-- log phase:
local duration_ms = math.floor((ngx.now() - ngx.req.start_time()) * 1000)
local ttft_fb = ctx.sse_first_byte_ms or 0
local ttft_c  = ctx.sse_content_ms or 0
if not ctx.sse_is_stream then            -- JSON: body arrives whole
    ttft_fb, ttft_c = duration_ms, duration_ms
end
```

Entry JSON gains `ttft_first_byte_ms`, `ttft_content_ms`, `duration_ms`.
Client-cancel-before-first-byte is representable: `aborted=1` with
`ttft_first_byte_ms = 0 < duration_ms`.

### 2.3 Schema: `conf/migrations/000008_add_ttft_duration.{up,down}.sql`

```sql
-- up
ALTER TABLE llm_gateway.usage_log
    ADD COLUMN IF NOT EXISTS ttft_first_byte_ms UInt32 DEFAULT 0 AFTER is_stream,
    ADD COLUMN IF NOT EXISTS ttft_content_ms   UInt32 DEFAULT 0 AFTER ttft_first_byte_ms,
    ADD COLUMN IF NOT EXISTS duration_ms       UInt32 DEFAULT 0 AFTER ttft_content_ms;
DROP TABLE IF EXISTS llm_gateway.billing_ledger_mv;   -- SELECT is frozen at CREATE
CREATE MATERIALIZED VIEW llm_gateway.billing_ledger_mv
TO llm_gateway.billing_ledger AS
SELECT ... (existing columns unchanged) ...,
    ttft_content_ms AS ttft_ms,
    duration_ms     AS llm_latency_ms,
    ...
FROM llm_gateway.usage_log;
```

`conf/clickhouse-init.sql` gains the three columns in both the CREATE TABLE
and the MV, plus the idempotent `ADD COLUMN IF NOT EXISTS` ALTER block
(house style). Down migration drops the columns and restores the old MV
SELECT (zeros).

## 3. Cruncher

### 3.1 Orchestrator `res/scripts/crunch-usefulness.sh`

Mirrors `backfill-reasoning-tokens.sh` (curl + ClickHouse HTTP, `set -euo
pipefail`, flags `--dry-run --rebuild --days N --since TS --limit N`, env
`CLICKHOUSE_HOST/PORT`, `PODMAN_BIN`/`PODMAN_PATH`, `APISIX_CONTAINER`,
`FLUSH_WINDOWS`).

Window math: default `--days 1`; windows are aligned hours with a 1h safety
lag (late inserts excluded by design). Efficiency and idempotency mechanics:

1. One prequery fetches the DISTINCT non-empty hourly windows in range; the
   loop never touches an empty window (no month-of-nulls churn).
2. `--rebuild` drops + recreates `request_signals` from the canonical DDL
   extracted out of `conf/clickhouse-init.sql` (single source of truth -
   never hand-written SQL).
3. Rows are crunched per window but committed in blocks of `FLUSH_WINDOWS`
   (default 12): one span DELETE + one INSERT per block. Per-window inserts
   tripped ClickHouse's inactive-parts guard (TOO_MANY_PARTS at 1002) on the
   706-window backfill; blocking keeps parts bounded and block-aligned spans
   keep runs idempotent.
4. Insert errors capture and print the ClickHouse response body (no `-f`
   swallowing).
5. A `flock` guards concurrent runs; the apisix container is resolved via
   compose labels so a stale `gw-prod-apisix` is never picked.

Per window, the fetch (TSV) pre-extracts in ClickHouse:
```sql
SELECT request_id, model, toString(timestamp),
       if(length(arr) > 1, 1, 0),
       if(last_usr = '', '', last_usr)
FROM (
  SELECT request_id, model, timestamp,
         arrayFilter(m -> JSONExtractString(m, 'role') = 'user',
             JSONExtractArrayRaw(req_body, 'messages')) AS usr_msgs,
         arrayFilter(m -> JSONExtractString(m, 'role') = 'assistant',
             JSONExtractArrayRaw(req_body, 'messages')) AS asst_msgs,
         usr_msgs[length(usr_msgs)] AS last_raw,
         -- content is a string (chat) or array of parts (Responses API)
         if(typeOf(JSONExtractRaw(last_raw, 'content')) = 'String',
            JSONExtractString(last_raw, 'content'),
            arrayStringConcat(arrayMap(
              p -> JSONExtractString(p, 'text'),
              arrayFilter(p -> JSONHas(p, 'text'),
                JSONExtractArrayRaw(last_raw, 'content'))), ' ')) AS last_usr,
         arrayMap(m -> JSONExtractString(m, 'role'),
             JSONExtractArrayRaw(req_body, 'messages')) AS arr
  FROM llm_gateway.request_log
  WHERE timestamp >= '{T0}' AND timestamp < '{T1}'
    AND uri LIKE '%/chat/completions%' OR uri LIKE '%/responses%'
    AND req_body != '' AND JSONExtractString(req_body, 'model') != ''
)
FORMAT TabSeparated
```
(is_followup = assistant message exists anywhere in the history; column
projection simplified: final SQL fixes the OR-parenthesis and emits
`is_followup` from `asst_msgs` directly. Unparseable bodies select out as
empty `last_usr` and are inserted as `parsed=0` zero-signal rows, FR-2.7.)

2. Match:
```bash
podman exec -i apisix /usr/local/openresty/luajit/bin/luajit \
    /usr/local/apisix/usefulness/cruncher.lua \
    /etc/apisix/profanity/en.txt \
    /etc/apisix/profanity/frustration-phrases.txt \
    /etc/apisix/profanity/vader-negative.txt \
    < rows.tsv > matched.tsv
```
Compose addition: mount `../../conf/profanity:/etc/apisix/profanity:ro` and
`../../res/scripts/usefulness:/usr/local/apisix/usefulness:ro` on the apisix
service (both compose files).

3. Commit window (idempotency):
```sql
ALTER TABLE llm_gateway.request_signals DELETE
  WHERE timestamp >= '{T0}' AND timestamp < '{T1}';
INSERT INTO llm_gateway.request_signals FORMAT TabSeparated < matched.tsv
```
Concurrent-run note: two simultaneous runs converge because each writes only
complete aligned windows; a `flock /tmp/crunch-usefulness.lock` in the shell
wrapper removes even that race (belt and braces, cheap).

`--dry-run` prints per-window row counts and match stats, writes nothing.

### 3.2 `res/scripts/usefulness/cruncher.lua` (pure stdlib)

I/O contract: reads field-per-line records (tab-separated: request_id,
model, ts, is_followup, message; message may span multiple TSV-escaped
lines: orchestrator emits `FORMAT TabSeparated` which escapes newlines as
`\n`; Lua unescapes), writes one TSV result row per input row:
`request_id, model, ts, is_followup, parsed, profane, profane_count,
[term\t]…, frustrated, frustration_count, [term\t]…, signal_count,
signal_weight`. `signal_weight` = Σ per-instance weights: 1.0 for each
profanity/frustration-phrase occurrence, `round(|valence|/4.0, 2)` for each
VADER-negative word occurrence (REQ FR-5.7; the VADER file carries
`word<TAB>valence` so weights are data-driven, not hardcoded). Array fields
use ClickHouse TabSeparated quoting (`['a','b']`, backslash-escaped).

Script-mode argv: `en.txt phrases.txt vader-negative.txt fuzzy-blocklist.txt
dict_version`: 5+ args runs the TSV filter; fewer means library mode (the
Lua tests require it as a module).

Algorithms:

- **Tokenize:** lowercase, `’`→`'`, then `gmatch("[%a%d'']+")`: strips
  punctuation but keeps apostrophes ("doesn't" stays one token).
- **Profanity fuzzy, precision-gated:** exact `words[t]` always. Fuzzy only
  when the token's length passes the distance gate: `max_dist_for(n)`:
  2 if n ≥ 9, 1 if n ≥ 5, else 0: and the token is NOT in the common-English
  blocklist. Candidate lookup via SymSpell delete indexes built at load
  (delete-1 variants of dict words ≥ 4 chars, delete-2 of words ≥ 8),
  confirmed with bounded Levenshtein (early-exit at maxDist). Short-token
  distance-1 is where English collides (how~hoe, help~hell, list~lust,
  that~twat, book~boob, tool~fool); the blocklist kills the long-token
  collisions (where~whore, parsing~pissing, batch~bitch, fetch~felch,
  parse~arse, chunk~chink). "f*ck" fails tokenization ("f","ck"): accepted
  ceiling; the dictionary itself ships many variant spellings.
- **Phrases (frustration list):** each phrase indexed by its longest word
  (anchor). A message is a candidate only where an anchor token appears;
  sliding spans of phrase-length ±20% words pass a length-ratio prefilter,
  then character-trigram Jaccard ≥ 0.7 confirms.
- **VADER-negative single words:** exact match only (no fuzziness: the
  lexicon is ordinary English like "pathetic", fuzzy recall there is pure
  false-positive surface).
- **Dedup & precedence:** profanity matches recorded first; frustration
  spans overlapping an already-matched profanity token are dropped.
  VADER entries already removed from file at build (FR-3.3).
- **Occurrences:** every match appends the canonical dictionary term to
  the result arrays: a term appearing 15 times appends 15 entries.

Size ceiling (ponytail: linear scans per message, ~600 dict phrases ×
rare-word-gated candidates; if 13-month backfill proves slow, precompute
per-model monthly partitions and parallelize windows: upgrade path, not
built now).

## 4. Schema: `request_signals` + dictionary tables

```sql
CREATE TABLE IF NOT EXISTS llm_gateway.request_signals (
    request_id        String,
    model             LowCardinality(String),
    timestamp         DateTime64(3),
    is_followup       UInt8,
    parsed            UInt8 DEFAULT 1,
    profane           UInt8,
    profane_count     UInt16,
    profane_terms     Array(String),
    frustrated        UInt8,
    frustration_count UInt16,
    frustration_terms Array(String),
    signal_count      UInt16,
    signal_weight     Float32,
    guard_blocks      UInt16 DEFAULT 0,
    guard_rules       Array(String) DEFAULT [],
    user_rejections   UInt16 DEFAULT 0,
    rule_denials      UInt16 DEFAULT 0,
    dict_version      LowCardinality(String) DEFAULT ''
) ENGINE = ReplacingMergeTree()
ORDER BY (model, timestamp, request_id)
PARTITION BY toYYYYMM(timestamp)
TTL toDateTime(timestamp) + INTERVAL 13 MONTH
SETTINGS index_granularity = 8192,
         parts_to_delay_insert = 500,
         parts_to_throw_insert = 1000,
         inactive_parts_to_delay_insert = 500,
         inactive_parts_to_throw_insert = 1000,
         max_parts_in_total = 5000;
```

The four friction columns (migration `000009_add_friction_columns`) are
computed by SQL string functions in the crunch INSERT (§5); the `--rebuild`
DDL extraction picks them up automatically from `clickhouse-init.sql`.

`dict_version` = sha256 prefix of the concatenated dictionary files at
crunch time (audit, FR-3.4). ReplacingMergeTree keyed on request_id makes
even non-aligned duplicate inserts self-healing at query time via
`FINAL`/`argMax` if ever needed: but the aligned-window delete+insert is
the primary idempotency mechanism (FR-2.2).

Dictionary mirror tables are unnecessary for queries (matching is offline)
and are intentionally **not** created: YAGNI; the files are the source of
truth.

## 5. Friction Telemetry (guard blocks, user rejections, rule denials)

### 5.1 Marker provenance (stable protocol interfaces)

| Class | Exact marker (as it appears verbatim in `req_body` tool results) | Source of truth |
|-------|------------------------------------------------------------------|-----------------|
| Shell-guard block | `BLOCKED: bash -c '<cmd>' (<rule>) (<ISO-8601>)` or `BLOCKED: bash <script> (<scope>) (<rule>) (<ISO-8601>)`: live transcripts show one **or** two parentheticals before the timestamp; the rule id is always the last one | ../WORKSPACE-GUARD `docs/specifications/SPEC-SHELL-GUARD.md` §6.1; rule ids from `config/shell_guard_policy.yaml` |
| Git-guard block | `BLOCKED: ts=<RFC3339>Z\|reason=<pct-encoded>\|…` | ../WORKSPACE-GUARD `docs/specifications/SPEC-GIT-GUARD.md` §7.1 |
| User rejection | `The user rejected permission to use this specific tool call` (suffix `. You may try again…` or ` with the following feedback: …`) | ../opencode `packages/core/src/v1/permission.ts` (`PermissionRejectedError`, `CorrectedError`) |
| Rule denial | `The user has specified a rule which prevents you from using this specific tool call.` | ../opencode `packages/core/src/v1/permission.ts` (`PermissionDeniedError`) |

Shell-guard rule-id taxonomy (stable ids, from the policy YAML):
`power-verb, process-by-name, power-command, fs-destroy, alt-shell,
busybox-shell, kill-mass, chattr-strip, rm-rootfs, dd-device,
mount-protected, swap-teardown, suppress-pipe, suppress-null,
suppress-swallow, alt-interp, podman-command, inline-shell,
uv-inline-interp, inline-code-channel`, plus the script-scope tag
`script body` (not a rule id).

Live-transcript verification (2026-09-16, 80-day corpus, 34,110 non-empty
bodies): **25,834** requests carry guard `BLOCKED:` text, **356** the
user-rejection marker, **957** the rule-denial marker. Observed shape:

```json
{"role":"tool","tool_call_id":"call_…","content":"BLOCKED: bash tests/… (script body) (suppress-pipe) (2026-09-16T08:20:35+00:00)\n  -> Hint: …"}
```

### 5.2 Extraction SQL (inside the crunch fetch; no Lua matching, no second pass)

ClickHouse TabSeparated output escapes `'` as `\'`, so SQL must NOT build the
`['a','b']` array literal (it would double-mangle on the way through). SQL
emits friction counts plus a plain comma-joined rule-id list (TSV-safe);
the Lua core re-encodes the csv into the ClickHouse array format via its
existing `ch_array`:

```sql
countMatches(req_body, 'BLOCKED: bash ') + countMatches(req_body, 'BLOCKED: ts=')  AS guard_blocks,
arrayStringConcat(extractAll(req_body, '[(]([a-z][a-z0-9-]+)[)] [(]2[0-9]{3}-[0-9]{2}-[0-9]{2}T'), ',') AS guard_rules_csv,
countMatches(req_body, 'The user rejected permission to use this specific tool call') AS user_rejections,
countMatches(req_body, 'The user has specified a rule which prevents you from using this specific tool call') AS rule_denials
```

The rule-id regex uses `[(]`/`[)]` character classes (no backslashes: no
bash/SQL escaping pitfalls) and anchors on "lowercase-hyphen parenthetical
immediately followed by the ISO-timestamp parenthetical", so the optional
`(script body)` scope tag (followed by the rule parenthetical, not a
timestamp) cannot match, and git-guard `reason=` percent-encoded payloads
cannot produce fake ids.

### 5.3 Semantics and known biases

- **Attribution:** counts attach to the model of the request whose stored
  body contains the marker: the model that operated under that friction.
- **Lower bound (C-8):** opencode breaks the agent loop on permission
  rejection; the marker reaches `request_log` only when the conversation
  continues in a later request that replays the tool result. Panels must
  label counts as a lower bound.
- **Quoting overcount:** a model *discussing* guard output (e.g. reading
  guard docs) also produces `BLOCKED:` text. One-directional, small,
  accepted ceiling: `ponytail:` refine with a `"role":"tool"`-only JSON
  prefilter if it ever matters.
- **Truncation (C-3):** bodies cut at 256 KiB may drop markers; consistent
  with the `parsed=0` coverage stance (FR-2.7).
- Guard-side audit sinks (`/var/log/workspace-guard/`, root-only, C-7)
  remain authoritative for security; this telemetry is the *model-experience*
  view. No cross-join planned.

## 6. Model Score Family (Overall = adherence × reliability, REQ FR-9 revised)

Revised 2026-09-16 per Q10. The original weighted-linear score (arithmetic
sum, min-max normalization against observed extrema, satisfaction + friction +
speed merged) is replaced by a construct-separated, goalpost-standardized,
geometrically aggregated family. Grounding: SUM (Sauro & Kindlund 2005 -
standardize against specification limits, not observed extrema; equal
construct weights), HDI (UNDP 2010: geometric mean so no dimension can
substitute for another), Tan et al. 2026 (arXiv 2604.06183: latency's effect
on perceived quality is non-monotone, so speed informs routing, not the
score), Nielsen 0.1/1/10s limits (performance dashboard bands).

### 6.1 Constructs and goalposts (fixed constants, never observed extrema)

| Construct | Raw rate | Index | Goalpost (rate → index 0) |
|-----------|----------|-------|---------------------------|
| Followup rejection | absolute share of followup requests whose last user message carries a profanity or frustration signal (`100 × rej_n / fu`) | `clamp(1 − rate/50, 0, 1)` | 50% |
| Session abandonment | share of sessions containing the model that end on a different model (`argMax(model, timestamp)` per session, `groupUniqArray`, ARRAY JOIN: window-free by necessity: ClickHouse window functions inside CTEs return 0 without an error under joins) | `clamp(1 − rate/100, 0, 1)` | 100% |
| Client cancel | `countIf(aborted=1)/countIf(is_stream=1)` | `clamp(1 − rate/5, 0, 1)` | 5% |
| Provider abort (Reliability) | `countIf(aborted=2)/countIf(is_stream=1)` | `clamp(1 − rate/5, 0, 1)` | 5% |

The rejection rate is absolute, not baseline-differenced. The earlier
`followup − base-prompt` subtraction was removed 2026-09-16: base samples run
31-267 rows per model, and a single operator's base style varies by era, so
differencing clamped genuinely bad models to 0 net rejection (terra: 52.3%
followup signals vs 54.7% on a 203-row base → net 0 while being the worst
model in the fleet). The absolute followup rate matches p32's displayed rate
and needs no baseline at all.

A factor with no measurable data counts neutral 0.5 (`ifNull`); a MEASURED
factor that reaches its goalpost is floored at 0.05 instead of 0 ,  the
geometric mean annihilates the whole composite on any zero component (the
UNDP 2010 zero-collapse critique, Anand et al.), which turned a 52.3%-vs-50%
goalpost crossing into a full-zero Overall for terra and made the composite
hyper-sensitive to one constant. Models require ≥ 30 requests (kills the
tiny-sample ties the old ≥2-model gate produced). Session abandonment is
contaminated by multi-model interleaving (sessions that alternate models
penalize every participant): documented on the panels as a heuristic.

### 6.2 Composition

```
PAI       = (rej_idx × abandonment_idx × cancel_idx) ^ (1/3)   # geometric mean
Reliability = abort_idx
Overall   = 100 × sqrt(PAI × Reliability)                     # constructs equal, geometric
```

**Construct separation is mandatory**: friction (§5) and speed (§ FR-7 /
performance dashboard) are excluded from PAI and Overall. Friction is an
agent-environment construct (shown as context columns and dedicated panels);
speed is a routing input. This is the direct lesson of the v1 critique: a
model cannot buy back rejection language or aborts with fast tokens.

### 6.3 Scorecard (p41)

One row per model: Requests, raw rates (Followup Rejection %, Switches %, Cancels
%, Aborts %), standardized indices (n Rejection, n Switches, n Cancels,
n Reliability), PAI (0-100), Overall Score, and Friction per 100 as a context
column (explicitly not part of either composite). Bands: ≥ 70 good (green),
40-69 mixed (yellow), < 40 poor (red); panels carry the behavioral-heuristic
annotation.

## 7. Dashboards `conf/grafana/dashboards/gateway-model-experience.json` + `gateway-model-performance.json`

Split 2026-09-16 from the former monolithic `gateway-usefulness` dashboard:
**Model Experience** (9 panels, ids 32-34/37/38/40-43: Overall Score +
scorecard, rejection rate/baseline/net, top rejection strings, session depth,
model switch, friction rate, top guard rules; carries `rejection_mode` and
`include_local`) and **Model Performance** (5 panels, ids 30/31/36/44/45 -
prefill/decode speed p50, cancel/abort rates, wasted tokens & cost, cost +
time per completed response). Renamed uid `gateway-model-experience` /
`gateway-model-performance`.

Conventions: identical to SPEC-DASHBOARD §3 variables plus:

- `rejection_mode`: custom variable, options `binary` / `instances`
  (default `binary`, no All option: it is a calculation-mode toggle, not
  a filter; `allValue: "binary"` kept only to satisfy the S6f quoted-
  context guard).
- `include_local`: custom variable, options `include : yes` /
  `exclude : no` (default `exclude`, `allValue: yes` per REQ-DASHBOARD
  FR-3.3). Both verdict panels (p40/p41) append
  `AND ('${include_local}' = 'yes' OR model NOT IN (SELECT model FROM
  llm_gateway.model_registry WHERE is_local = 1))`; `model_registry` is
  materialized by `res/scripts/sync-model-registry.sh` (`make
  gw-sync-model-registry`) from `conf/providers/*.yaml` `local: true`
  flags. Migrated timing (2026-09-17) also lights the speed and avg-latency
  panels for all models: the migration now writes `duration_ms` /
  `ttft_content_ms` from opencode `time.completed` + first non-reasoning
  part timestamps, and `upstream_response_time_s = duration_ms / 1000`.
- Relevance gate CTE used by every per-model query:
```sql
WITH gated AS (
  SELECT model FROM llm_gateway.usage_log
  WHERE $__timeFilter(timestamp) AND model != ''
  GROUP BY model HAVING count() >= 100
)
```

### Panel-by-panel (ids 30-45)

| ID | Panel | Query core |
|----|-------|-----------|
| 30 | Prefill Speed by Model (bargauge, p50) | `medianExactIf(prompt_tokens / nullIf(ttft_content_ms,0) * 1000, ttft_content_ms >= 100)` over `is_stream=1`, model IN gated; avg branch removed 2026-09-17 (p50 only), full fleet coverage via migrated timing |
| 31 | Cancel / Provider-abort rate (stat ×2) | `100 * countIf(aborted=1) / count()` over streams; same for `aborted=2` |
| 32 | Rejection rate stat (mode-aware) | both branches return strings (ClickHouse `if()` requires a common type): binary: `concat(toString(round(100 * countIf(signal_count > 0 AND is_followup=1) / nullIf(countIf(is_followup=1),0), 2)), '%')` (trailing `%` since 2026-09-17); instances: `toString(round(sum(signal_weight) / nullIf(countIf(is_followup=1),0), 2))`; selected via `if('${rejection_mode}' = 'instances', …, …)`; **no per-message cap** (REQ FR-5.3) |
| 33 | (removed 2026-09-17) | Baseline-vs-reactive + signed-net chart deleted: the baseline-differencing interpretation it visualized was retired with the absolute-rate rejection metric (§6.1); the scorecard's `Rej % / n` column is the decomposition now |
| 34 | Top rejection terms (table) | merged profane + frustration table, `arrayJoin(profane_terms) AS term, count()` … `ORDER BY count DESC LIMIT 15`, censored |
| 35 | (removed 2026-09-17) | Signals-over-time panel deleted: heavy per-bucket query, dubious reader value; p33 + p42 cover the time dimension |
| 36 | Wasted tokens & cost (stat) | `sum(if(aborted>0, completion_tokens, 0))` **plus rejected tool calls**: `lagInFrame` of the generation preceding a marker-bearing request (`user_rejections + rule_denials + guard_blocks > 0`, same session) with `prev_ab = 0` so aborted generations are never double-counted; the same attribution adds `prev_cost`, so waste $ covers both sources; B/M/K compact token strings; `$` exact waste cost |
| 37 | Session depth by model (bargauge) | messages per `session_id` from request_log, avg per model, gated |
| 38 | (removed 2026-09-17) | Model-switch timeseries deleted: it cannot discern a mid-session switch caused by a usage limit from one caused by user decision, so the per-bucket trend carried no decision value; the switch factor itself stays in the score (§6.2) and its per-model value is visible in the scorecard `Sw % / n` column |
| 39 | (removed 2026-09-17) | Historical decode proxy deleted: migrated `duration_ms`/`ttft_content_ms` make native per-message timing dominate |
| 40 | **Overall Score leaderboard** (bargauge) | §6.2 composition; one row per qualifying model, verdict-colored bands ≥70/40, "behavioral heuristic" annotation; honours `include_local` |
| 41 | **Scorecard** (table) | §6.3 un-rolled CTE; since 2026-09-17 each rate column merges its normalized index into one cell (`"26.68% / 0.47"`) under short headers (`Rej % / n`, `Sw % / n`, `Canc % / n`, `Abr % / n`, `PAI`, `Overall`, `Fric /100`) with `wrapText` so nothing clips; honours `include_local` |
| 42 | **Friction rate** (stacked timeseries) | per model per bucket: `100 × (guard_blocks + user_rejections + rule_denials) / count()`, split by class (three series), `HAVING count() >= 5`, description notes lower-bound + quoting caveats |
| 43 | **Top guard rules** (table/bar) | `arrayJoin(guard_rules) AS rule, count()` … `ORDER BY count DESC LIMIT 15` |
| 44 | Decode Speed by Model (bargauge, p50) | `medianExactIf(completion_tokens / nullIf(duration_ms − ttft_content_ms, 0) * 1000, duration_ms − ttft_content_ms >= 100)`, p50 only since 2026-09-17 |
| 45 | Cost & Time per Completed Response (stat, avg) | `sumIf(cost, aborted=0) / countIf(aborted=0)`, `avgIf(duration_ms, aborted=0 AND duration_ms > 0) / 1000`, completed count (compact B/M/K); explicitly labeled averages (budget math needs means; p50 lives on the speed panels) |

All queries filter `${api_key:singlequote}` where key-scoped and
`${model:singlequote}` where model-scoped, per REQ-DASHBOARD FR-3.4. New
dashboard refresh stays 5s (reads are tiny aggregates over
`request_signals`/`usage_log`).

### 7.1 Scheduling (REQ NFR-1.6)

`res/systemd/gateway-usefulness-crunch.service` (Type=oneshot, runs
`res/scripts/crunch-usefulness.sh --days 1` as the deploy user with
`CLICKHOUSE_HOST=localhost`) + `gateway-usefulness-crunch.timer`
(`OnCalendar=*-*-* 00:00:00`, `Persistent=true` to catch missed runs after
downtime, `Unit=` bound, `RandomizedDelaySec=300`). `make
gw-crunch-usefulness` runs the script directly (manual/same code path);
`make gw-install-crunch-timer` installs and enables the timer via the
existing systemd deployment path.

REQ-DASHBOARD FR-1.1 amendment (3→5 dashboards, +15 panels) lands in the
same MR as the dashboard JSON.

## 8. Tests

| Test | What |
|------|------|
| `tests/lua/test_usefulness_cruncher.lua` | runs under container luajit like `tests/config/test_model_registry.sh`; cases: exact/fuzzy profanity (`fuuuck`, `useles`), phrase trigram hits ("thats not what i asked for"), 15-occurrence weighting, dedup precedence, canonicalization, TSV escaping round-trip, `parsed=0` passthrough |
| `tests/lua/test_sse_usage_lib.lua` | `has_content` on first content delta only; reasoning_content counts; JSON-mode ttft=duration; cancel-before-first-byte row shape |
| `tests/config/test_clickhouse_sql.sh` | 000008 up/down idempotent; MV recreated with real ttft wiring; request_signals DDL present; 000009 friction columns; §5.2 marker expressions present in the crunch INSERT; `--rebuild` DDL extraction includes friction columns |
| `tests/integration/test_crunch_idempotency.sh` | seed window via `seed-clickhouse-dashboard-data.sh` pattern; run cruncher twice; `SELECT * ORDER BY request_id` byte-identical; concurrent `flock` run safe |
| `tests/config/test_dashboard_usefulness.sh` | structure via `dashboard_assert.sh`; `rejection_mode` variable exists; gate CTE `>= 100` present in every per-model rawSql; no `req_body` reference in any rawSql; score panel carries the weights CTE + verdict thresholds + <2-model NULL guard; friction panels reference the three marker columns; panels 40-43 present |
| `tests/integration/test_usefulness_queries.sh` | synthetic rows: denominator discipline (per-model), sparse-bucket NULL, no-cap raw sums, binary/instances equivalence on known data, signed-net math, marker-count correctness on seeded bodies containing all four marker classes |

All wired into `tests/run_all.sh` stages and gated by `make check`.

## 9. File Map

| File | Purpose |
|------|---------|
| `plugins/custom/sse-usage.lua`, `plugins/custom/sse_usage_lib.lua` | TTFT/duration stamps |
| `conf/migrations/000008_add_ttft_duration.{up,down}.sql` | usage_log columns + MV recreation |
| `conf/clickhouse-init.sql` | same, initdb path |
| `conf/profanity/en.txt`, `vader-negative.txt`, `frustration-phrases.txt`, `fuzzy-blocklist.txt` | vendored dictionaries (snapshots; blocklist generated) |
| `res/scripts/update-dictionaries.sh` | dictionary refresh + blocklist generation |
| `res/scripts/crunch-usefulness.sh` | orchestrator |
| `res/scripts/usefulness/cruncher.lua` | matching core (pure stdlib Lua) |
| `conf/grafana/dashboards/gateway-model-experience.json` + `gateway-model-performance.json` | dashboards |
| `Makefile` | `gw-update-dictionaries`, `gw-crunch-usefulness` targets |
| `tests/…` | per §8 |

## 10. Implementation Status

| Component | Status | Evidence |
|-----------|--------|----------|
| TTFT/duration capture | Implemented | plugins/custom/sse-usage.lua, sse_usage_lib.lua; tests/lua/test_sse_usage_lib.lua (content_detection_tests) |
| Migration 000008 + MV wiring | Implemented | conf/migrations/000008_add_ttft_duration.{up,down}.sql; conf/clickhouse-init.sql |
| Dictionaries vendored + refresh target | Implemented | conf/profanity/*; res/scripts/update-dictionaries.sh; make gw-update-dictionaries |
| Cruncher (shell + Lua) | Implemented | res/scripts/crunch-usefulness.sh, res/scripts/usefulness/cruncher.lua; make gw-crunch-usefulness |
| request_signals table | Implemented | migration 000008 + conf/clickhouse-init.sql |
| systemd timer (daily 00:00) | Implemented | res/systemd/gateway-usefulness-crunch.{service,timer}; make gw-install-crunch-timer |
| model experience + performance dashboards | Implemented | conf/grafana/dashboards/gateway-model-{experience,performance}.json; tests/config/test_dashboard_{experience,performance}.sh |
| Tests | Implemented | tests/lua/test_usefulness_cruncher.lua; tests/integration/test_crunch_idempotency.sh; extended test_clickhouse_sql.sh, test_grafana_provisioning.sh, dashboard_assert.sh |
| Friction telemetry (§5) | Implemented | migration 000009 + crunch INSERT expressions + panels 42-43; live backfill 2026-09-16 |
| Usefulness Score (§6) | Implemented | panels 40-41 + weights CTE; 12 models scored live |
| Readability refinements (REQ FR-10.2/3/4/5) + 2026-09-17 operator pass | Implemented | threshold bands (p31/p40); p50-only speed panels (p30/p44) with full fleet coverage via migrated timing; rejected-tool-call waste in p36 (lagInFrame prev-generation attribution, no double count); p45 standalone completed-response averages; scorecard %/index merged cells under short wrap-enabled headers; p32 trailing %; p35 signals-over-time, p33 baseline-vs-reactive and p38 model-switch timeseries removed (baseline differencing retired; switch cause is indiscernible); include_local toggle (p40/p41) backed by `model_registry` (`make gw-sync-model-registry`); tiered layouts: experience: 40/41 → 32/37 → 34/42/43; performance: 30/44 → 31/36/45 |

## 11. References (research grounding, 2026-09-16)

- agent-native.com/docs/observability: Frustration Index: weighted
  behavioral signals → 0-100 with interpretation bands; feedback +
  satisfaction tabs alongside latency/tool-success.
- lillytechsystems.com LLM production-readiness monitoring patterns -
  golden-signals single view; user-satisfaction proxies (regeneration,
  abandonment, retry) as first-class KPIs; current-vs-baseline framing.
- futureagi.com LLM eval vs product analytics: quality+cost+outcome as
  three tiles joined on a shared session id, not collapsed into one tool.
- github.com/Daniel5569/llm-evaluation-observability-platform -
  weighted-score composites with deterministic verdict thresholds and a
  metric-by-metric scorecard (the decomposable-score pattern of §6).
