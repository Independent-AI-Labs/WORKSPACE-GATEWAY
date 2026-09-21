# REQ-USEFULNESS-TELEMETRY: Practical-Usefulness Metrics

**Date:** 2026-09-16
**Status:** Active
**Type:** Requirements
**Specification:** [SPEC-USEFULNESS-TELEMETRY](../specifications/SPEC-USEFULNESS-TELEMETRY.md)

> Mandates the measurement of **practical usefulness** of served models from
> observed user behavior: the opposite of benchmark maximization: how fast
> tokens actually arrive (TTFT-derived prefill/decode speed), how often users
> cancel, how often users reject a model's output (profanity + negativity
> language in follow-up turns, weighted by volume), and what that wasted
> engagement costs. Adds one Lua capture extension, one periodically-runnable
> idempotent batch cruncher (Lua core), two vendored dictionaries, one new
> ClickHouse signals table, and a 4th Grafana dashboard.

---

**Cross-references:**
- [SPEC-USEFULNESS-TELEMETRY](../specifications/SPEC-USEFULNESS-TELEMETRY.md): implementation specification
- [REQ-BILLING-TELEMETRY.md](REQ-BILLING-TELEMETRY.md): owns `usage_log` schema and the sse-usage → ClickHouse write path this feature extends
- [REQ-DASHBOARD.md](REQ-DASHBOARD.md): owns dashboard structural rules; its FR-1.1 was amended from 3 to 5 dashboards by this feature
- [architecture/OPEN-ISSUES.md](../architecture/OPEN-ISSUES.md): request_id join caveats affecting the historical tok/s proxy

---

## 1. Purpose & Scope

### 1.1 Purpose

Answer, per model (with ≥ 100 logged responses), from production traffic:

1. **Speed as experienced:** prefill and decode tokens/second derived from
   TTFT and total stream duration: not provider benchmarks.
2. **Friction:** user-cancelled response rate and provider-aborted rate.
3. **Rejection:** rate at which users respond to a model's output with
   profanity or frustration language, weighted by the volume of such language
   (15 profanities in one message weigh more than 1), with a user-togglable
   counting mode.
4. **Cost of failure:** tokens and dollars spent on responses users discarded;
   effective cost per completed response.
5. **Engagement quality:** session continuation depth and mid-session model
   switching (escalation).
6. **Friction:** how often tool actions in the agent conversation were
   blocked by the host guard or rejected by the user (observable in stored
   conversation bodies via exact protocol markers).
7. **One comparable number:** a per-model **Usefulness Score** (0-100)
   integrating rejection, friction, aborts, and speed so models can be
   ranked on practical usefulness at a glance, with per-factor drill-down.

### 1.2 Scope

**This document OWNS the requirements for:**
- TTFT and stream-duration capture in `sse-usage.lua` (the only signal not
  derivable from existing stores)
- The batch rejection-language cruncher: idempotent, periodically runnable,
  Lua-core, reading `request_log` history and writing a signals table
- Dictionary sourcing, licensing, vendoring, and refresh
- Rejection weighting, counting-mode toggle, and normalization semantics
- The `gateway-model-experience` and `gateway-model-performance` Grafana dashboards and their queries
- Derived metric definitions (tok/s, wasted tokens, effective cost, session
  depth, model-switch rate) and the ≥ 100-response relevance gate

**This document DOES NOT:**
- Change billing ownership or cost calculation (REQ-BILLING-TELEMETRY, REQ-COST-CALC)
- Define dashboard structural rules (REQ-DASHBOARD FR-6.x applies as-is)
- Introduce ML-based response-quality scoring (explicit non-goal; see Open
  Questions for the llamafile upgrade path)
- Add real-time/in-request-path language matching (crunching is batch-only)

### 1.3 Terminology

| Term | Definition |
|------|------------|
| TTFT (first-byte) | ms from gateway request start to the first non-empty response body chunk observed in `body_filter` |
| TTFT (content) | ms from gateway request start to the first SSE event carrying non-empty content or reasoning text; the default TTFT for metrics |
| Duration | ms from gateway request start to stream end (completion or abort) |
| Follow-up message | a request whose `messages` history contains at least one assistant response before the last user message (i.e. the user has seen the model's prior output) |
| Baseline message | a first-turn user message (no preceding assistant response) |
| Rejection signal | a fuzzy-matched profanity instance or frustration-language instance in a follow-up user message |
| Reactive rejection | rejection signals in follow-up messages (the model is the likely target) |
| Baseline rate | signal rate in first-turn messages (user's habitual style; normalization reference) |
| Binary mode | rejection counted per message: a message with ≥ 1 signal counts once |
| Instances mode | rejection counted per matched instance: a message with 15 matches contributes 15 |
| Rejection density | instances-mode aggregate: capped signal instances per follow-up message |
| Signal instance | one matched occurrence, deduplicated across dictionaries (profanity precedence) |
| Aligned window | a time bucket with boundaries on fixed hour boundaries, used for idempotent reprocessing |
| Guard block | a tool action blocked by WORKSPACE-GUARD (shell guard `BLOCKED: bash …` or git guard `BLOCKED: ts=`), visible as literal text in the stored conversation body |
| User rejection | a tool call the user explicitly refused (opencode `PermissionRejectedError` / corrected-variant marker strings) |
| Rule denial | a tool call refused by client permission rules (opencode `PermissionDeniedError` marker string), not by the user interactively |
| Friction | per-model aggregate of guard blocks + user rejections + rule denials per 100 requests |
| Usefulness Score | weighted 0-100 composite per model over normalized factors (FR-9); the single cross-model comparison metric |

## 2. Functional Requirements

### FR-1: TTFT and Duration Capture (request path, Lua)

| ID | Requirement |
|----|-------------|
| FR-1.1 | `sse-usage.lua` MUST record `ttft_first_byte_ms` at the first non-empty `body_filter` chunk as `(ngx.now() - request_start_time) * 1000`, at most once per request. |
| FR-1.2 | `sse_usage_lib` SSE scanning MUST additionally report the first content-bearing event (non-empty `content` or `reasoning_content` delta, or non-empty text part in JSON responses-API frames) so `sse-usage.lua` can stamp `ttft_content_ms`. |
| FR-1.3 | `sse-usage.lua` `log` phase MUST compute `duration_ms` as `(ngx.now() - request_start_time) * 1000` and MUST include `ttft_first_byte_ms`, `ttft_content_ms`, `duration_ms` in the `usage_log` entry JSON. |
| FR-1.4 | For non-stream (JSON) responses, both TTFT columns MUST equal `duration_ms` (whole body arrives at once). |
| FR-1.5 | Aborted streams (client or provider) MUST still carry timing columns; a cancel before first byte is the strongest negative latency signal and MUST be distinguishable (`ttft_first_byte_ms = 0` with `duration_ms > 0`). |
| FR-1.6 | `usage_log` schema MUST gain `ttft_first_byte_ms UInt32 DEFAULT 0`, `ttft_content_ms UInt32 DEFAULT 0`, `duration_ms UInt32 DEFAULT 0` via a new migration and `conf/clickhouse-init.sql`. |
| FR-1.7 | The `billing_ledger_mv` materialized view MUST be recreated (DROP + CREATE; its SELECT is frozen at creation) so `billing_ledger.ttft_ms` receives `ttft_content_ms` and `llm_latency_ms` receives `duration_ms`; rows written before this change keep their historical zeros. |
| FR-1.8 | Request-path overhead added by FR-1.1-1.3 MUST be O(1) per chunk (two integer stamps and one boolean check); no dictionary matching or regex work may run in the request path. |

### FR-2: Batch Cruncher (periodic, idempotent, Lua core)

| ID | Requirement |
|----|-------------|
| FR-2.1 | The system SHALL provide `res/scripts/crunch-usefulness.sh` + `res/scripts/usefulness/cruncher.lua` that recompute rejection-language signals from `request_log.req_body` into `llm_gateway.request_signals` with no request-path involvement. |
| FR-2.2 | A run processes only complete aligned windows (default trailing 1 day, hourly buckets, configurable via `--days`/`--since`); it MUST prequery the set of non-empty hourly windows and never issue queries for empty ones. Windows are committed in blocks (default 12, `FLUSH_WINDOWS`): per block, DELETE that block's span from `request_signals` before re-inserting, making repeated, overlapping, or concurrent runs convergent (100% idempotent) while keeping ClickHouse part creation bounded. `--rebuild` MUST drop and recreate `request_signals` from the canonical DDL in `conf/clickhouse-init.sql` for clean recomputes. |
| FR-2.3 | The orchestrator MUST support `--dry-run`, `--days N`, `--since TS`, `--limit N` and MUST fail loudly (non-zero exit, no partial window commits) on ClickHouse or Lua errors. |
| FR-2.4 | ClickHouse MUST pre-extract per-row the last `role=user` message text and the follow-up flag (JSON functions in the SELECT); the Lua core MUST NOT parse JSON (TSV in, TSV out) and MUST run on the APISIX container's openresty luajit (host has no Lua). |
| FR-2.5 | The Lua matching core MUST be pure stdlib Lua (no `resty.*`, no cjson) so it is testable under plain luajit. |
| FR-2.6 | `request_signals` MUST store, per request: `request_id`, `model`, `timestamp`, `is_followup UInt8`, `parsed UInt8`, `profane UInt8`, `profane_count UInt16`, `profane_terms Array(String)` (one canonical entry per matched occurrence), `frustrated UInt8`, `frustration_count UInt16`, `frustration_terms Array(String)` (one canonical entry per matched occurrence), `signal_count UInt16` (deduplicated occurrence count), `signal_weight Float32` (Σ valence-factored weights, FR-5.7). Raw message text MUST NOT be stored (privacy: matched terms only). |
| FR-2.7 | Rows whose `req_body` is empty or unparseable (e.g. truncated at the 256 KiB http-logger cap) MUST be recorded with zero signals and `parsed=0` so coverage bias is measurable, never hidden. |

### FR-3: Dictionaries

| ID | Requirement |
|----|-------------|
| FR-3.1 | Profanity source SHALL be `coffee-and-fun/google-profanity-words` `data/en.txt` (MIT; release v3.0.7 Apr 2026; ~962 lowercase entries). |
| FR-3.2 | Negativity/frustration source SHALL be the strongly-negative subset of the VADER lexicon (`cjhutto/vaderSentiment`, MIT; valence ≤ −2.0) plus a vendored, gateway-owned chat-correction phrase list (`conf/profanity/frustration-phrases.txt`, seeded ~60 phrases like "not what i asked", "wrong answer", "try again", "still broken"). |
| FR-3.3 | Normalized snapshots of all dictionaries MUST be committed (reproducible deploys) under `conf/profanity/` (including the generated `fuzzy-blocklist.txt`); `make gw-update-dictionaries` MUST re-fetch upstream, normalize (lowercase, trim, dedupe), exclude any negativity entry already present in the profanity list (dedup precedence, deterministic), generate the fuzzy blocklist, and write the files. |
| FR-3.4 | Dictionary refresh MUST NOT change historical `request_signals` content unless the affected windows are explicitly re-crunch (`--since`); dictionary version at crunch time MUST be recorded per window (audit column on the window delete+insert). |
| FR-3.5 | Dictionary content MUST NOT be modified by the pipeline beyond normalization (no added/removed words at runtime). |

### FR-4: Matching Semantics (batch Lua)

| ID | Requirement |
|----|-------------|
| FR-4.1 | Tokenization: lowercase UTF-8, word characters plus apostrophes; punctuation split. |
| FR-4.2 | Profanity matching MUST be fuzzy but precision-gated: exact match always; fuzzy only for tokens of length >= 5 (edit distance <= 1) and >= 9 (distance <= 2), and never for tokens present in the generated common-English blocklist (`conf/profanity/fuzzy-blocklist.txt`, built from google-10000-english + the VADER lexicon + a coding-context supplement). This excludes collisions like where~whore, parsing~pissing, batch~bitch, fetch~felch, parse~arse, chunk~chink, how~hoe, that~twat. Exact dictionary hits are unaffected by the blocklist. |
| FR-4.3 | Phrase matching (frustration list, multi-word entries) MUST use normalized trigram similarity ≥ 0.7 with a ±20% length-ratio prefilter. |
| FR-4.4 | Every matched occurrence counts separately: a message containing a term 15 times contributes 15 instances (the weighting requirement). |
| FR-4.5 | Dedup: a token/span matched by both dictionaries counts once, under profanity (precedence); VADER entries duplicated in the profanity list are removed at dictionary-build time (FR-3.3), so runtime overlap is limited to fuzzy collisions. |
| FR-4.6 | Matched occurrences MUST be canonicalized to the dictionary entry (not the user's spelling) so ranking aggregates variants. |

### FR-5: Rejection Metrics, Weighting, and Normalization

| ID | Requirement |
|----|-------------|
| FR-5.1 | REMOVED 2026-09-17 (operator order): the `rejection_mode` toggle and its consumer panel (p32) are deleted. The metric it switched (`signal_count`/`signal_weight` aggregates) is vader/frustration/profanity lexicon coverage of follow-up messages, not user rejections (explicit `user_rejections` events measure 1.21% vs 37.39% lexicon coverage on the same window); presenting it under a rejection name was wrong. Explicit rejection counts remain via `user_rejections` in the scorecard (FR-8) and friction panels (FR-7). |
| FR-5.2 | Binary mode: `rejection rate %` = 100 × (follow-up messages with `signal_count > 0`) / (follow-up messages), per model. Bounded [0, 100]. |
| FR-5.3 | Instances mode: `rejection intensity` = Σ `signal_weight` / (follow-up messages), per model, with **no per-message cap** (raw sums; outliers are signal, not noise: a message with 15 matches contributes 15 × weight). Unit: weighted instances per message; NOT a percentage and MUST NOT be rendered as one. |
| FR-5.4 | Denominator discipline: every rate/density denominator MUST be the count of follow-up messages **of the same model in the same time bucket**; cross-model pooling is forbidden in per-model panels. |
| FR-5.5 | Sparse buckets: time-bucket aggregates with fewer than 5 follow-up messages for a model MUST render as absent (NULL), not 0. |
| FR-5.6 | Baseline (first-turn) signal rate MUST be displayed alongside reactive rejection. The `net rejection` view is the **signed** per-bucket difference `reactive − baseline` plotted around a zero reference line (positive = worse than the user's habitual style, negative = better); it MUST NOT be clamped at zero (clamping would erase genuinely positive signals) and MUST be labeled as a heuristic correction, never replacing raw numbers. |
| FR-5.7 | Instance weights (uniform-with-valence-factoring): profanity and frustration-phrase instances weigh 1.0; VADER-negative word instances weigh `round(|valence| / 4.0, 2)` (valence ∈ [−4.0, −2.0] subset → weight ∈ [0.5, 1.0]). Weights are applied at query time from the stored `signal_weight` column; binary mode ignores weights. |

### FR-6: `gateway-model-experience` + `gateway-model-performance` Dashboards

| ID | Requirement |
|----|-------------|
| FR-6.1 | Two provisioned dashboards: `gateway-model-experience` (uid `gateway-model-experience`, satisfaction/friction panels: ids 34, 37, 40-43) and `gateway-model-performance` (uid `gateway-model-performance`, speed/reliability/waste panels: ids 30, 31, 36, 44, 45): MUST follow REQ-DASHBOARD structural rules (FR-6.x there) and define the same `api_key` + `model` multi-value template variables; `include_local` lives only on the experience dashboard. |
| FR-6.2 | Every per-model query MUST gate on `count() >= 100` responses in the dashboard time range (relevance floor); models below the floor MUST be excluded from rankings and tables. |
| FR-6.3 | Panels (minimum set): (a) prefill tok/s and decode tok/s per model: avg and p50, from `ttft_content_ms`/`duration_ms`; (b) cancel rate (`aborted=1`) and provider-abort rate (`aborted=2`); (c) rejection rate/density per FR-5 with baseline companion; (d) top profanities and top frustration terms ranked by total occurrences (`arrayJoin`); (e) time series of cancel%, rejection rate/density, provider-abort% per bucket, normalized per model per bucket (FR-5.4/5.5), with multiple models overlayable on one chart via the existing multi-select variable; (f) wasted tokens + effective cost per completed response; (g) session depth and mid-session model-switch rate. |
| FR-6.4 | Until `ttft_content_ms` accumulates, tok/s panels MUST use the labeled historical proxy: decode tok/s ≈ `completion_tokens / upstream_response_time_s` via the request_id join (estimate, flagged in-panel), prefill tok/s unavailable historically. |
| FR-6.5 | Dashboard queries MUST read `request_signals` / `usage_log` only; no query MAY scan `req_body` at refresh time. |

### FR-7: Derived Metric Definitions

| ID | Requirement |
|----|-------------|
| FR-7.1 | Prefill tok/s = `prompt_tokens / (ttft_content_ms / 1000)`; decode tok/s = `completion_tokens / ((duration_ms − ttft_content_ms) / 1000)`; rows with `duration_ms ≤ ttft_content_ms` or non-positive denominators MUST be excluded from these aggregates (never negative or infinite values). |
| FR-7.2 | Wasted tokens = Σ tokens of aborted responses; effective cost per completed response = Σ cost / count of non-aborted responses. |
| FR-7.3 | Session depth = messages per `session_id`; model-switch = a request whose `session_id` continues but `model` differs from the previous request in that session (per model receiving the switch). |

### FR-8: Friction Telemetry (guard blocks, user rejections, rule denials)

| ID | Requirement |
|----|-------------|
| FR-8.1 | The cruncher MUST count, per stored request body, occurrences of the exact friction markers: (a) shell-guard blocks: lines matching `BLOCKED: bash ` (formats `BLOCKED: bash -c '…' (<scope>)? (<rule>) (<ISO-8601>)` and `BLOCKED: bash <script> (<scope>)? (<rule>) (<ISO-8601>)`); (b) git-guard blocks: lines starting `BLOCKED: ts=`; (c) user rejections: the opencode marker `The user rejected permission to use this specific tool call` (covers both the plain and with-feedback variants); (d) rule denials: the opencode marker `The user has specified a rule which prevents you from using this specific tool call`. Marker strings are client/guard protocol (provenance in SPEC §5); they MUST be treated as stable interfaces and re-verified on client upgrade. |
| FR-8.2 | For shell/git guard blocks the rule id MUST be extracted where present: the last `(<lowercase-hyphen id>)` parenthetical immediately preceding the ISO-8601 timestamp parenthetical, stored one entry per block in `guard_rules Array(String)`. Unknown/absent rule ids contribute to counts but not to the rules array. |
| FR-8.3 | Friction extraction MUST run as SQL string functions (`countMatches`/`extractAll`) inside the existing crunch pass: no Lua involvement, no second pass, no request-path work: and MUST land in the same idempotent window delete+insert as language signals. |
| FR-8.4 | `request_signals` MUST gain `guard_blocks UInt16`, `guard_rules Array(String)`, `user_rejections UInt16`, `rule_denials UInt16` (DEFAULT 0/empty); raw body text beyond rule ids MUST NOT be stored. |
| FR-8.5 | Friction metrics presented per model: friction rate = 100 × (guard_blocks + user_rejections + rule_denials) / requests; top guard rules ranked by occurrences (`arrayJoin(guard_rules)`); stacked time series per bucket of the three friction classes, sparse-bucket-suppressed per FR-5.5. |
| FR-8.6 | Attribution: friction counts attach to the model of the request whose body carries the marker text (the model that operated under / reacted to that friction). Known visibility bias MUST be documented on the dashboard: a user rejection may end the agent turn without an immediate follow-up request (opencode breaks the loop on rejection), so the marker is only observed when the conversation continues in a later request: counts are a **lower bound**, not a census. |

### FR-9: Model Score Family (Overall = adherence × reliability, geometric)

> Revised 2026-09-16 (Q10): the original weighted-linear score conflated user
> satisfaction, tool friction and speed, normalized against observed extrema
> (rankings thrashed with the model population), and let speed buy back
> dissatisfaction. The revision is grounded in SUM (Sauro & Kindlund 2005),
> the HDI geometric mean (UNDP 2010), Nielsen response-time limits, and
> Tan et al. 2026 (arXiv 2604.06183).

| ID | Requirement |
|----|-------------|
| FR-9.1 | The system SHALL define one **Overall Score** per model, 0-100 (higher = better), computed at query time from already-stored columns, as **Overall = 100 × sqrt(PAI × Reliability)**: geometric aggregation across constructs so no factor can compensate for another (HDI 2010 rationale). |
| FR-9.2 | **PAI (Prompt Adherence Index)** = geometric mean of three goalpost-standardized user-side indices, each `clamp(1 − rate/goalpost, 0, 1)`: followup rejection-signal rate (goalpost 50%; absolute share of followup requests whose last user message carries a profanity or frustration signal ,  the base-prompt subtraction was removed: base samples are 31-267 rows and the same user's style varies by era, so differencing clamped genuinely bad models to 0 net rejection), session abandonment (goalpost 100%; share of sessions containing the model that end on a different model, computed window-free via `argMax(model, timestamp)` per session: ClickHouse window functions inside CTEs return 0 without an error under joins), client cancel rate (goalpost 5%). |
| FR-9.3 | **Reliability** = `clamp(1 − provider_abort_rate/5%, 0, 1)`. A factor with no measurable data counts neutral 0.5 (ifNull); models require ≥30 requests. Goalposts are fixed constants, never observed extrema. |
| FR-9.4 | **Construct separation is mandatory**: friction (FR-8) and speed (FR-7) MUST NOT enter PAI or Overall. Friction is an agent-environment construct, shown as context columns / dedicated panels; speed is a routing input, shown on the performance dashboard (Tan et al. 2026: latency-perceived-quality is non-monotone). |
| FR-9.5 | Interpretation bands MUST be shown: ≥ 70 good (green), 40-69 mixed (yellow), < 40 poor (red); a per-construct decomposition (raw rates, standardized indices, PAI, Reliability, Overall, friction as context) MUST accompany the score so the composite is never a black box  -  since 2026-09-19 delivered by the score cards' hover face (p47), which superseded the p41 scorecard table. Both panels carry the behavioral-heuristic caveat and the session-abandonment contamination warning (multi-model interleaving inflates abandonment for models used in mixed workflows). |
| FR-9.6 | The score is a heuristic ranking aid over behavioral proxies, not a quality certification; panels MUST carry a "behavioral heuristic" annotation. |

### FR-10: Dashboard Refinement (readability)

| ID | Requirement |
|----|-------------|
| FR-10.1 | New panels on `gateway-model-experience`: (a) **Usefulness Score leaderboard**: one bargauge row per qualifying model, verdict-colored per FR-9.5; (b) *(superseded 2026-09-19)* **scorecard table** replaced by the (e) score cards' hover decomposition; (c) **friction rate** stacked timeseries with the three FR-8.5 classes; (d) **top guard rules** ranked bar (like top-profanities); (e) *(added 2026-09-19)* **score cards** (p47): one flat HTML card per qualifying model rendered by the Business Text panel (`marcusolsson-dynamictext-panel`, preinstalled via `GF_PLUGINS_PREINSTALL`; the env var takes bare IDs only  -  no version-pin syntax, grafana.com catalog serves the latest compatible release)  -  big score headline, verdict-colored accent (good/mixed/poor per FR-9.5), PAI + request count beneath; a CSS-only hover card-flip carries the full per-model decomposition (each rate with its index, PAI, friction); single score-family query (`renderMode: allRows`), same >=30-request gate + `include_local` toggle as p40; template HTML passes Grafana's DOMPurify sanitizer (`disable_sanitize_html` remains false). |
| FR-10.2 | Readability rules for existing panels: rate gauges carry green/amber/red threshold bands; speed panels show p50 only (the avg branch was removed 2026-09-17: one number per panel, migrated timing covers the full fleet); every ratio panel states its denominator in the description; sparse buckets stay absent per FR-5.5. The historical tok/s proxy was removed once native per-message timing (migrated `duration_ms`/`ttft_content_ms`) dominated. |
| FR-10.3 | Human-readable presentation: every table column and stat series carries a human name + unit (quoted SQL aliases / `displayName` overrides: no `A cancel_pct`-style identifiers); the top-terms panel becomes a single merged **Top User Rejection Strings** table (Category column, no A/B tabs) with profanity terms censored to first/last character (`b***h`). (The mode-aware rejection stat and its title/unit rules were removed with FR-5.1 on 2026-09-17.) |
| FR-10.4 | Waste is quantified in absolute terms, proportionally and monetarily: wasted tokens (compact B/M/K), wasted as % of all completion tokens, and $ cost of wasted tokens as an exact `"$x.yy"` string (REQ-DASHBOARD FR-7.1). Waste MUST include both aborted streams AND the tokens of generations whose tool call was rejected (guard block, user permission rejection, or rule denial): attributed via the preceding request in the same session, never double-counting an aborted generation. Cost per completed response lives on its own panel (p45) with the average time per completed response and the completed count, explicitly labeled as averages (p50 stays on the speed panels). |
| FR-10.5 | Panels are split across two dashboards, each grouped in tiers. `gateway-model-experience`: Verdict (score + score cards) → session depth → top strings + friction + guard rules. `gateway-model-performance`: prefill p30 / decode p44 side by side (separate panels so the ~40k prefill and ~100 decode scales never share an axis) → cancel/abort + waste + completed-response averages. Row-keyed bargauges use all-values reduce (one gauge per model). |
| FR-10.6 | Each rate MUST be presented together with its normalized index (since 2026-09-19: pre-merged as `"x% (idx y)"` strings in the p47 cards' SQL), and Overall Score + score cards MUST honour an `include_local` toggle (default exclude) filtering `llm_gateway.model_registry WHERE is_local = 1`, materialized from `conf/providers/*.yaml` `local: true` flags by `make gw-sync-model-registry`. |

## 3. Non-Functional Requirements

| ID | Requirement |
|----|-------------|
| NFR-1.1 | Request-path latency added by FR-1 MUST be negligible (two `ngx.now()` calls and boolean checks per stream). |
| NFR-1.2 | A full re-crunch of all retained history MUST be resumable window-by-window and MUST NOT lock or block dashboard queries beyond ClickHouse's normal merge behavior. |
| NFR-1.3 | No raw user text beyond what already exists in `request_log` may be created; `request_signals` stores matched terms only. |
| NFR-1.4 | Dictionary snapshots and cruncher are versioned in-repo; deploys are reproducible without network access. |
| NFR-1.5 | All new tests MUST run under the existing `make check` gates. |
| NFR-1.6 | The cruncher MUST be scheduled daily at 00:00 local time via a systemd timer (with the manual `make gw-crunch-usefulness` target invoking the same unit); scheduling MUST be installed by the existing deployment automation. |

## 4. Constraints

| ID | Constraint | Source |
|----|------------|--------|
| C-1 | ClickHouse is the analytics store; no PostgreSQL exists in the stack | RUNTIME-TOPOLOGY |
| C-2 | Host has no Lua interpreter; Lua runs in the APISIX container (`/usr/local/openresty/luajit/bin/luajit`), as existing tests already do | tests/config/test_model_registry.sh |
| C-3 | `req_body` is capped at 256 KiB by http-logger; over-cap sessions truncate and may lose the last user message | conf/apisix.yaml |
| C-4 | Dictionary licenses: MIT (google-profanity-words) and MIT (VADER lexicon) | GitHub API, 2026-09-16 |
| C-5 | Prometheus exports no first-byte/TTFT metric; total request latency only | research, REQ-DASHBOARD FR-4.10 |
| C-6 | MV SELECT expressions are immutable after creation; wiring ledger columns requires MV recreation | ClickHouse semantics |
| C-7 | Guard audit logs (`/var/log/workspace-guard/`) are root-only; the gateway can observe blocks only as marker text inside stored conversation bodies | WORKSPACE-GUARD README |
| C-8 | opencode breaks the agent loop on permission rejection by default; rejected tool markers reach `request_log` only via later turns' replayed context | ../opencode packages/opencode/src/session/processor.ts |

## 5. Assumptions

| ID | Assumption |
|----|-------------|
| A-1 | `usage_log.aborted` semantics (0/1/2) remain as defined in REQ-DASHBOARD A-1. |
| A-2 | The last `role=user` entry in `messages` is the current human turn; earlier ones are quoted history. |
| A-3 | Follow-up profanity targets the model's prior output often enough to be a useful rejection proxy; first-turn rate captures habitual style (research-supported: implicit behavioral signals outperform explicit ratings). |
| A-4 | `request_log.request_id` joins to `usage_log.request_id` well enough for the labeled historical proxy (OPEN-ISSUES caveats accepted). |
| A-5 | Proxy buffering stays disabled on relay routes (first chunk ≈ upstream send time). |

## 6. Open Questions (raised for timely discussion)

| ID | Question | Default if unanswered |
|----|----------|----------------------|
| Q1 | TTFT default: content-token TTFT (reasoning models stream reasoning first) vs first-byte TTFT | **Resolved 2026-09-16:** capture both; dashboards use content |
| Q2 | Instance weighting: uniform 1.0 vs VADER-valence-scaled | **Resolved 2026-09-16:** uniform 1.0 for profanity/phrases, valence-factored for VADER words (FR-5.7) |
| Q3 | Toggle placement: Grafana variable (query-side) vs cruncher config (stored) | **Resolved 2026-09-16:** Grafana variable |
| Q4 | Instances-mode per-message cap | **Resolved 2026-09-16:** no cap: raw sums (FR-5.3) |
| Q5 | Net-rejection visualization | **Resolved 2026-09-16:** signed difference around zero, not clamped (FR-5.6) |
| Q6 | Scheduling cadence for the cruncher | **Resolved 2026-09-16:** daily at 00:00 via systemd timer (NFR-1.6) |
| Q7 | Upgrade path: local llamafile-hosted small classifier for rejection scoring (later, out of scope) | Documented as future work only |
| Q8 | Score factor weights (FR-9.4) | **Resolved 2026-09-16 (defaults):** rejection 0.30, friction 0.20, cancel 0.10, provider abort 0.10, prefill 0.15, decode 0.15: tuned so behavioral factors (0.60) outweigh speed (0.30); single CTE, edit to re-tune |
| Q9 | Friction counting basis: whole body vs last message | **Resolved 2026-09-16:** whole stored body: markers live in replayed tool results anywhere in the visible context |
| Q10 | Score-family revision of the original weighted-linear FR-9 (which conflated satisfaction/friction/speed, normalized against observed extrema, and allowed compensatory trade-offs). **Resolved 2026-09-16: implemented per FR-9 (revised):** Overall = sqrt(PAI × Reliability) with fixed goalposts and geometric aggregation; PAI = prompt-adherence indices (followup rejection 0-50%, session abandonment 0-100%, client cancel 0-5%); friction and speed excluded as separate constructs (friction context columns + dedicated panels; speed on the performance dashboard). Research grounding: SUM (Sauro & Kindlund 2005: z-vs-specification-limit standardization, equal construct weights via PCA), HDI geometric mean (UNDP 2010: no substitutability across dimensions; Anand critique: goalpost sensitivity), Nielsen 0.1/1/10s response-time limits, Tan et al. 2026 (arXiv 2604.06183: 2s responses rated *less* thoughtful than 9-20s: speed-quality non-monotone, so speed informs routing, not the score), SPUR (ACL 2024: interpretable satisfaction rubrics). |

## 7. Verification Matrix

| # | Test (planned) | Maps to |
|---|------|---------|
| V1 | `tests/lua/test_usefulness_cruncher.lua` (tokenizer, SymSpell fuzzy, trigram phrase, dedup, canonicalization) | FR-4.x, FR-2.5 |
| V2 | `tests/lua/test_sse_usage_lib.lua` extension (content-event detection, ttft stamps) | FR-1.1-1.5 |
| V3 | `tests/config/test_clickhouse_sql.sh` extension (migration 000008, MV recreation, request_signals DDL) | FR-1.6, FR-1.7, FR-2.6 |
| V4 | `tests/integration/test_crunch_idempotency.sh` (run twice over same window → identical content) | FR-2.2, FR-2.3 |
| V5 | `tests/config/test_dashboard_experience.sh` + `test_dashboard_performance.sh` + `dashboard_assert.sh` | FR-6.x |
| V6 | `tests/integration/test_usefulness_queries.sh` (normalization invariants: denominators, NULL sparse buckets, cap, mode toggle equivalence) | FR-5.x, FR-7.x |
| V7 | `tests/config/test_clickhouse_sql.sh` extension: friction columns in DDL + migration, marker SQL present in crunch insert | FR-8.3, FR-8.4 |
| V8 | `tests/config/test_dashboard_experience.sh` extension: score panel (weights CTE, bands, <2-model suppression), friction panels, scorecard | FR-9.x, FR-10.x |
| V9 | Live marker probe: counts for all four marker classes > 0 on the current 80-day corpus (regression canary for client upgrades) | FR-8.1 |

## 8. Implementation Status

| Item | Status | Evidence |
|------|--------|----------|
| FR-1.x TTFT/duration capture | Implemented | plugins/custom/sse-usage.lua (body_filter stamps, log-phase duration); plugins/custom/sse_usage_lib.lua (has_content); conf/migrations/000008_add_ttft_duration.{up,down}.sql; conf/clickhouse-init.sql |
| FR-2.x batch cruncher | Implemented | res/scripts/crunch-usefulness.sh + res/scripts/usefulness/cruncher.lua; compose mounts in res/docker/docker-compose{,.prod}.yml and tests/docker-compose.test.yml |
| FR-3.x dictionaries | Implemented | conf/profanity/{en.txt,vader-negative.txt,frustration-phrases.txt} + README; res/scripts/update-dictionaries.sh; make gw-update-dictionaries |
| FR-4.x matching semantics | Implemented | res/scripts/usefulness/cruncher.lua (SymSpell delete-1, bounded Levenshtein, trigram phrases, dedup precedence); tests/lua/test_usefulness_cruncher.lua |
| FR-5.x weighting/normalization | FR-5.1 removed (2026-09-17 operator order: rejection_mode + p32 deleted); weighting remains at storage level | request_signals.signal_weight; gateway-model-experience.json (per-bucket denominators, sparse-bucket HAVING) |
| FR-6.x dashboard | Implemented | conf/grafana/dashboards/gateway-model-experience.json (6 panels) + gateway-model-performance.json (5 panels); tests/config/test_dashboard_experience.sh + test_dashboard_performance.sh; REQ-DASHBOARD FR-1.1 amended to 5 dashboards |
| FR-7.x derived metrics | Implemented | dashboard p30/p36/p37/p38/p39 queries |
| NFR-1.6 daily 00:00 scheduling | Implemented | res/systemd/gateway-usefulness-crunch.{service,timer}; make gw-install-crunch-timer |
| FR-8.x friction telemetry | Implemented | migration 000009 + conf/clickhouse-init.sql; marker SQL in res/scripts/crunch-usefulness.sh; live 2026-09-16 backfill: 13,467 guard blocks (2,964 requests), 81 user rejections, 52 rule denials, 13 rule ids |
| FR-9.x score family | Implemented | gateway-model-experience.json p40/p47 (Overall = sqrt(PAI × Reliability), fixed goalposts 50/100/5/5, geometric aggregation, ≥30-request gate, friction/speed excluded); live: 12 models ranked, kimi-k3 88.7 / glm-5.3 81.9 / glm-5.2 0.0 |
| FR-10.x dashboard refinement | Implemented | p40-p43 + p50-only speed panels (p30/p44, full fleet via migrated timing); FR-10.3/4/5 readability pass (censored merged strings table, %/USD waste, human names, tiered layout split across experience/performance dashboards); FR-10.6 merged scorecard cells + include_local toggle; p35/p39 removed, p45 added; test_dashboard_experience.sh 74/74 + test_dashboard_performance.sh 53/53 |
