# REQ-DASHBOARD: Gateway Grafana Dashboards

**Date:** 2026-07-17
**Status:** Active
**Type:** Requirements
**Specification:** [SPEC-DASHBOARD](../specifications/SPEC-DASHBOARD.md)

> Mandates 5 Grafana dashboards (32 panels total) giving the gateway operator a
> real-time and historical view of LLM traffic, cost, latency, errors,
> internal health, and practical usefulness. Dashboard JSON files under
> `conf/grafana/dashboards/` are the
> single source of truth for structure; this document owns the correctness and
> consistency requirements. Known cross-table data-quality issues are tracked in
> [architecture/OPEN-ISSUES.md](../architecture/OPEN-ISSUES.md), not here.
> The 4th and 5th dashboards (`gateway-model-experience`,
> `gateway-model-performance`) are specified in
> [REQ-USEFULNESS-TELEMETRY](REQ-USEFULNESS-TELEMETRY.md); this document owns
> only their structural conformance (FR-3.x/FR-6.x here apply as-is).

---

**Cross-references:**
- [SPEC-DASHBOARD](../specifications/SPEC-DASHBOARD.md): panel-by-panel query specification
- [architecture/OPEN-ISSUES.md](../architecture/OPEN-ISSUES.md): known data-quality issues (ASOF join correctness, event_id misalignment, token-count divergence)
- [`conf/grafana/dashboards/gateway-cost-usage.json`](../../conf/grafana/dashboards/gateway-cost-usage.json): Cost & Usage dashboard
- [`conf/grafana/dashboards/gateway-ops-health.json`](../../conf/grafana/dashboards/gateway-ops-health.json): Operations & Health dashboard
- [`conf/grafana/dashboards/gateway-cost-leaderboard.json`](../../conf/grafana/dashboards/gateway-cost-leaderboard.json): Cost Leaderboard dashboard
- [`conf/grafana/dashboards/gateway-model-experience.json`](../../conf/grafana/dashboards/gateway-model-experience.json): Model Experience dashboard (specified by REQ-USEFULNESS-TELEMETRY)
- [`conf/grafana/dashboards/gateway-model-performance.json`](../../conf/grafana/dashboards/gateway-model-performance.json): Model Performance dashboard (specified by REQ-USEFULNESS-TELEMETRY)

---

## 1. Purpose & Scope

### 1.1 Purpose

Answer five operational questions: (1) how much are we spending, (2) is the
gateway up and handling traffic, (3) are users seeing errors, (4) is
performance acceptable, (5) is the gateway itself healthy.

### 1.2 Scope

**This document OWNS the requirements for:**
- The 3 dashboards defined here (21 panels) and their datasources; the 4th
  and 5th dashboards (`gateway-model-experience`, 6 panels +
  `gateway-model-performance`, 5 panels) are owned by
  [REQ-USEFULNESS-TELEMETRY](REQ-USEFULNESS-TELEMETRY.md) and inherits this
  document's FR-3 (global filters) and FR-6 (structural rules) requirements
- Global template variables (`api_key`, `model`) and time range defaults
- Cross-query consistency invariants and structural rules for all panels

**This document DOES NOT:**
- Define ClickHouse schema or the Vector ingestion pipeline
- Track known data-quality defects (see architecture/OPEN-ISSUES.md)
- Specify Grafana provisioning mechanics

### 1.3 Terminology

| Term | Definition |
|------|------------|
| CH | ClickHouse datasource (uid `clickhouse`) |
| Prom | Prometheus datasource (uid `prometheus`) |
| `$__timeFilter` | Grafana ClickHouse macro binding queries to the dashboard time range |
| Brand palette | teal `#70c1b3`, cerulean `#247ba0`, muted-teal `#8cada7`, gold `#ffe066`, bronze `#b7990d`, coral `#f25f5c`, celadon `#a5d0a8`, dark `#50514f`, cream `#f2f4cb`, ink `#110b11` |

## 2. Functional Requirements

### FR-1: Dashboard Inventory

| ID | Requirement |
|----|-------------|
| FR-1.1 | The system SHALL provide exactly 5 dashboards: `gateway-cost-usage` (4 CH panels: ids 3, 15, 8, 46), `gateway-ops-health` (13 panels: ids 1, 2, 4, 5, 7, 13, 14, 9, 10, 11, 12, 50, 51  -  8 CH + 5 Prom; p50 storage growth per REQ-SECURITY-HARDENING FR-4.3), `gateway-cost-leaderboard` (4 CH stat panels: ids 20, 21 podium + 22, 23 runner-ups), `gateway-model-experience` (6 CH panels: ids 34, 37, 40, 42, 43, 47; satisfaction signals, Usefulness Score + score cards, friction: behavioral requirements owned by REQ-USEFULNESS-TELEMETRY), and `gateway-model-performance` (5 CH panels: ids 30, 31, 36, 44, 45; speed, cancel/abort, waste: owned by REQ-USEFULNESS-TELEMETRY). |
| FR-1.2 | All 5 dashboards MUST open with time range `now-90d` to `now` and a 5-second refresh. |
| FR-1.3 | Panel types MUST be: 3=stat, 15=timeseries, 8=bargauge, 46=piechart, 1=stat, 4=stat, 2=stat, 5=timeseries, 7=piechart, 13=timeseries, 14=timeseries, 9=timeseries, 10=bargauge, 11=timeseries, 12=timeseries, 50=bargauge, 51=bargauge, 20=stat, 21=stat, 22=stat, 23=stat; usefulness panels per its own REQ. |

### FR-2: Datasources

| ID | Requirement |
|----|-------------|
| FR-2.1 | Token usage, cost, model distribution, total requests, error rate, status breakdown, stream stats, and per-model latency MUST use ClickHouse so `$__timeFilter` respects the dashboard time range and data survives restarts. |
| FR-2.2 | Active connections, request rate, latency percentiles, bandwidth, and shared-dict memory MUST use Prometheus for real-time `rate()`/`histogram_quantile()` semantics. |
| FR-2.3 | Total Requests (p1), Error Rate (p4), and Status Code Breakdown (p7) MUST NOT use Prometheus counters, which reset on container restart or use hardcoded windows. |
| FR-2.4 | The ClickHouse datasource MUST run as the readonly `grafana_ro` account with its password injected via provisioning `secureJsonData` from environment; dashboard SQL MUST NOT reference `request_bodies` (test-enforced; REQ-SECURITY-HARDENING FR-5.5/FR-3.4). |

### FR-3: Global Filters

| ID | Requirement |
|----|-------------|
| FR-3.1 | Every dashboard MUST define an `api_key` template variable from ClickHouse using `coalesce(nullIf(key_id,''), nullIf(api_key_id,''), 'unknown')` over `llm_gateway.request_log`. |
| FR-3.2 | Every dashboard MUST define a `model` template variable unioning `model` from both `request_log` and `usage_log`. |
| FR-3.3 | ClickHouse query variables (`api_key`, `model`) SHALL NOT set `allValue`; Grafana's native multi-value expansion is used. Constant two-state toggles consumed inside single-quoted SQL predicates (e.g. `include_local`) MUST set an explicit `allValue` so `$__all` never produces invalid SQL (dashboard_assert S6f). |
| FR-3.4 | Every filtered ClickHouse query MUST filter on `${api_key:singlequote}` and (where model-scoped) `${model:singlequote}`. |

### FR-4: Panel Behavioral Requirements

| ID | Requirement |
|----|-------------|
| FR-4.1 | p3 (Token Usage by Category) MUST display Input (uncached), Cached, Output (non-reasoning) and Reasoning token volumes as compact uppercase `B`/`M`/`K` strings, plus Total and the Monthly/Weekly/Daily run-rate averages as `tokens / $x.yy` strings (exact spend, never SI-abbreviated), single query/frame, 8 unique column aliases and 8 unique byName color overrides, no two tiles sharing a color (categories form a cool hue ramp, averages a neutral ramp). Tiles stay horizontal with `maxPerRow: 4`; Total carries a per-field `textSize` override. |
| FR-4.2 | p15 (Cost Over Time) MUST be a per-day bars timeseries of `round(sum(cost), 2)` bucketed by `toStartOfDay(timestamp)`; the selected models and keys are additive, so the bars sum to total range spend. |
| FR-4.3 | p1 (Total Requests) MUST count `request_log` rows within the time filter, with thresholds teal/gold at 1000/bronze at 10000. |
| FR-4.4 | p4 (Error Rate) MUST compute `countIf(status >= 400) * 100 / count()` (all 4xx + 5xx), with thresholds teal/1 gold/5 coral. |
| FR-4.5 | p2 (Active Connections) MUST use `apisix_nginx_http_current_connections{state="active"}` with an exact (non-regex) label match. |
| FR-4.6 | p5 (Request Rate) MUST use `sum(rate(apisix_http_status{key_hash=~"$api_key"}[5m]))` with fixed legend `requests/s`. |
| FR-4.7 | p7 (Status Code Breakdown) MUST be a donut piechart with `reduceOptions.values: true`, `palette-classic` color mode, and byName overrides for 200/401/429/499/504. |
| FR-4.8 | p13 (Stream Abort Rate) MUST compute client-aborted (`aborted=1`) and provider-aborted (`aborted=2`) percentages over `is_stream = 1` rows, clamped to [0, 100]. |
| FR-4.9 | p14 (Stream Status) MUST show stacked absolute counts for completed/client-aborted/provider-aborted streams. |
| FR-4.10 | p9 (Latency Percentiles) MUST plot p50/p95/p99 via `histogram_quantile` over `apisix_http_latency_bucket` multiplied by 1000 (ms), with the invariant p50 <= p95 <= p99. |
| FR-4.11 | p10 (Response Time p50 by Model) MUST be a bargauge of `quantile(0.5)(upstream_response_time_s)` per model, excluding zero-latency rows, LIMIT 20, rendered colorless in a single brand color. |
| FR-4.12 | p11 (Bandwidth) MUST use `sum(rate(apisix_bandwidth{...,type="ingress|egress"}[5m]))` (not bare `rate()`), one series per direction. |
| FR-4.13 | p8 (Model Distribution) MUST be a treemap of the top 20 models by token volume from `usage_log`, drawn by the in-repo `gateway-treemap` panel (`res/grafana-plugins/gateway-treemap`): each tile is labelled with the model (`textField: model`) and sized by its token volume (`sizeField: tokens`, unit `short`), filled with the single brand color (`#247ba0`). The tile face is built in (percent share on top in the largest, thin font, then the model name, then the token volume); the tooltip MUST be templated (`tooltipTemplate`) with the model's `sum(cost)` spend (`currencyUSD`, decimals 2). The panel MUST support and configure minimum and maximum tile-area constraints (`minTileArea` / `maxTileArea`) so small tiles are merged into one overflow tile rather than rendered below one pixel, and a dominant tile is capped. After the tiles are laid out and measured, the face MUST drop lines that do not fit: if the content height cannot hold all three lines the percent line is hidden, if it cannot hold name+value the name is hidden, and if the name is wider than the tile it is hidden. The percent line MUST be the largest and thinnest, with scaled spacing between it and the name. Tile fill MUST ramp from neutral grey `#50514f` (smallest) to `#247ba0` (largest) so saturation encodes size, and auto font size MUST scale on a cube root of tile area. Per-model identity colors are NOT used. |
| FR-4.14 | p12 (Shared Dict Memory) MUST plot `(1 - free/capacity) * 100` for the `key_cache` and `redact_state` dicts with exact `name="..."` matches, clamped to [0, 100], stepAfter interpolation. |
| FR-4.15 | p20/p21 (Leaderboards) MUST render the top 3 as a podium panel (enlarged fixed `textSize`, medal colors gold/silver/bronze) and ranks 4-10 as a separate runner-up panel (smaller fixed `textSize`, white tiles) - p22/p23 use `LIMIT 7 OFFSET 3` over the same ranked CTE. The tile value MUST be an exact `"$x.yy"` currency string and the tile name MUST carry rank, entity, and compact uppercase B/M/K token volume (`"1. kimi-k3 - 2.41B"`). |
| FR-4.16 | p46 (Provider Breakdown ($)) MUST be a donut piechart of `sum(cost)` grouped by `usage_log.provider_id` over the time range with api_key + model filters, showing vendor/credential spend concentration; the legend MUST be shown (`legend.showLegend: true`, placement right, `values: [value]`), on-slice labels hidden, and the hover tooltip MUST carry the provider plus its request and token volume. Slices use Grafana `palette-classic`; no explicit provider colors. |
| FR-4.17 | p50 (Storage Growth) MUST show bytes-on-disk per `llm_gateway` table from `system.parts` plus total/free space from `system.disks`, as a timeseries/stat pair using only `grafana_ro`-granted system tables; a unified alert on this panel MUST fire when free space drops below 20% (REQ-SECURITY-HARDENING FR-4.3). |
| FR-4.18 | Per-model panels MUST render colorless in a single brand color (`#247ba0`), not per-model identity colors. The former `model_palette`/`model_color_map` VIEWs and their deterministic alphabetical-rank coloring were retired (migration `000015_drop_model_colors`); no panel, query or test may reference them. |
| FR-4.19 | p3's Monthly/Weekly/Daily averages MUST be run-rate projections of the whole-range total (`total / elapsed_days * {days_in_month,7,1}`, `elapsed_days = greatest(dateDiff('second', $__fromTime, $__toTime)/86400, 1)`), not per-bucket means. |

### FR-5: Cross-Query Consistency

| ID | Requirement |
|----|-------------|
| FR-5.1 | p3 token conservation: total = input + cached + output + reasoning. |
| FR-5.2 | p14 stream partition: completed + client_aborted + provider_aborted = total streams. |
| FR-5.3 | p15: sum of per-minute cost equals total cost (tolerance 0.01). |
| FR-5.4 | p8: sum of per-model spend equals total cost over the range (top-20 rounding tolerance). |
| FR-5.5 | Single-key filtered totals MUST be <= unfiltered totals (p1, p3, p4). |

### FR-6: Structural Rules (All Panels)

| ID | Requirement |
|----|-------------|
| FR-6.1 | Every panel MUST have `title`, `type`, `datasource.uid`, `gridPos`, and >= 1 target; every target MUST have a `refId`. |
| FR-6.2 | ClickHouse targets MUST use `rawSql`; Prometheus targets MUST use `expr`. |
| FR-6.3 | ClickHouse targets MUST NOT contain `meta`, `editorType`, or `pluginVersion` keys (they trigger builder mode with an empty query). |
| FR-6.4 | Queries MUST NOT use `$__conditionalAll` macros. |
| FR-6.5 | All hex colors MUST come from the brand palette; leaderboard medal accents (white `#ffffff`, matte gold `#c9a44c`, silver `#a8a9ad`, bronze `#b07a3c`) are the only permitted additions. |

### FR-7: Value Formatting Standards (all dashboards)

| ID | Requirement |
|----|-------------|
| FR-7.1 | Currency on stat tiles MUST be an SQL-formatted exact string `"$x.yy"` (floor + left-padded cents); SI-abbreviated money (`$2.88K`) is forbidden. Timeseries axes may use `currencyUSD`. |
| FR-7.2 | Token volumes on tiles MUST be SQL-formatted compact uppercase `B`/`M`/`K` strings with 2 decimals and no unit word (Grafana `unit: short` renders "Bil"/"Mil" and is forbidden). |
| FR-7.3 | Measured rates, costs, speeds, and scores MUST display 2 decimals (display config + SQL `round(x, 2)`); raw counts stay integers. |
| FR-7.4 | Stat panels MUST render each tile-set from a single query/frame (multi-target stat frames drop string fields and prefix names with refIds); string-valued fields REQUIRE `textMode: value_and_name`; `reduceOptions.fields` regexes match post-override display names, so panels whose overrides rename fields MUST use `/./`. |

## 3. Non-Functional Requirements

| ID | Requirement |
|----|-------------|
| NFR-1.1 | Panels MUST render correctly from their own datasource in isolation, independent of known cross-table data-quality issues (see OPEN-ISSUES.md). |
| NFR-1.2 | All dashboards MUST load via Grafana provisioning without manual edits. |

## 4. Constraints

| ID | Constraint | Source |
|----|------------|--------|
| C-1 | ClickHouse database is `llm_gateway` (tables `request_log`, `usage_log`) | conf/sql/migrations |
| C-2 | Dashboard JSONs are the tested artifact; tests verify against this requirements doc, not JSON structure alone | earlier dashboard spec |

## 5. Assumptions

| ID | Assumption |
|----|------------|
| A-1 | `usage_log.aborted` encodes 0=completed, 1=client-aborted, 2=provider-aborted. |
| A-2 | `usage_log.is_stream = 1` marks streaming requests. |

## 6. Open Questions

None. (Datasource choices resolved: ClickHouse for time-range-respecting and
restart-persistent metrics, Prometheus for instantaneous rates/percentiles.)

## 7. Verification Matrix

| # | Test | Maps to |
|---|------|---------|
| V1 | [`tests/config/test_dashboard_cost_usage.sh`](../../tests/config/test_dashboard_cost_usage.sh) | FR-1.1, FR-4.1, FR-4.2, FR-4.13 |
| V2 | [`tests/config/test_dashboard_ops_health.sh`](../../tests/config/test_dashboard_ops_health.sh) | FR-4.3-FR-4.12, FR-4.14 |
| V3 | [`tests/config/test_dashboard_cost_leaderboard.sh`](../../tests/config/test_dashboard_cost_leaderboard.sh) | FR-4.15 |
| V4 | [`tests/config/dashboard_assert.sh`](../../tests/config/dashboard_assert.sh) | FR-6.x |
| V5 | [`tests/integration/test_dashboard_queries.sh`](../../tests/integration/test_dashboard_queries.sh), [`test_grafana_panels.sh`](../../tests/integration/test_grafana_panels.sh) | FR-5.x |

## 8. Implementation Status

| Item | Status | Evidence |
|------|--------|----------|
| FR-1.1 5 dashboards / 31 panels | Implemented | conf/grafana/dashboards/*.json (4+12+4+6+5 panels; experience: score/score-cards/rejection/friction, performance: prefill/decode speeds split p30/p44 + reliability + waste + completed-response averages; ops-health p50 storage growth lands with REQ-SECURITY-HARDENING) |
| FR-1.2 time range & refresh | Implemented | each dashboard: `now-90d`→`now`, `5s` |
| FR-2.x datasource split | Implemented | 11 CH + 5 Prom targets across dashboards |
| FR-3.x template variables | Implemented | `api_key` + `model` in all 5 dashboards |
| FR-4.x panel behaviors | Implemented | per-panel queries in dashboard JSONs |
| FR-5.x consistency invariants | Implemented (queries) | see OPEN-ISSUES.md for residual data-quality caveats |
| FR-6.x structural rules | Implemented | tests/config/dashboard_assert.sh |
