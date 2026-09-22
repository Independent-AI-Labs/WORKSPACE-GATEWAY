# SPEC-DASHBOARD: Gateway Grafana Dashboards Implementation

**Date:** 2026-07-17
**Status:** Active
**Type:** Specification
**Requirements:** [REQ-DASHBOARD](../requirements/REQ-DASHBOARD.md)

> Panel-by-panel query specification for the gateway dashboards.
> All queries below are transcribed from the deployed dashboard JSONs and
> verified against them. Known cross-table data-quality issues are tracked in
> [architecture/OPEN-ISSUES.md](../architecture/OPEN-ISSUES.md).

---

**Cross-references:**
- [REQ-DASHBOARD](../requirements/REQ-DASHBOARD.md): requirements
- [architecture/OPEN-ISSUES.md](../architecture/OPEN-ISSUES.md): known issues audit
- [`conf/grafana/dashboards/gateway-cost-usage.json`](../../conf/grafana/dashboards/gateway-cost-usage.json): uid `gateway-cost-usage` (panels 3, 15, 8, 46)
- [`conf/grafana/dashboards/gateway-ops-health.json`](../../conf/grafana/dashboards/gateway-ops-health.json): uid `gateway-ops-health` (panels 1, 2, 4, 5, 7, 13, 14, 9, 10, 11, 12, 50)
- [`conf/grafana/dashboards/gateway-cost-leaderboard.json`](../../conf/grafana/dashboards/gateway-cost-leaderboard.json): uid `gateway-cost-leaderboard` (panels 20-23)

---

## 1. Overview

| Dashboard | UID | Panels | Datasources |
|-----------|-----|--------|-------------|
| Gateway Cost & Usage | `gateway-cost-usage` | 3 (stat), 15 (timeseries), 8 (treemap), 46 (piechart) | 4 CH |
| Gateway Operations & Health | `gateway-ops-health` | 1, 2, 4, 5, 7, 13, 14, 9, 10, 11, 12, 50 | 7 CH + 5 Prom |
| Gateway Cost Leaderboard | `gateway-cost-leaderboard` | 20, 21 (podium stat, top 3, enlarged) + 22, 23 (runner-up stat, 4-10) | 4 CH |

All dashboards: time `now-90d`→`now`, refresh `5s`.

## 2. Architectural Principles

### 2.1 ClickHouse for history, Prometheus for live metrics

Metrics that must survive container restarts and respect the dashboard time
range (totals, error rate, status breakdown, cost, stream stats) query
ClickHouse with `$__timeFilter`. Instantaneous rates and percentiles query
Prometheus with `rate()`/`histogram_quantile()`.

### 2.2 rawSql-only ClickHouse targets

No `meta`/`editorType`/`pluginVersion` keys on ClickHouse targets; their
presence triggers the plugin's builder mode with empty `columns: []` and the
panel renders nothing.

### 2.3 Key identity normalization

All key filters use `coalesce(nullIf(key_id,''), nullIf(api_key_id,''), 'unknown')`
to normalize across rows that use either column.

### 2.4 Value formatting standards (all dashboards)

One logic per quantity type, identical in every panel (operator ruling
2026-09-17; enforced by dashboard_assert S18):

- **Currency on standalone money tiles** = SQL-formatted exact `"$x.yy"`
  strings via rollover-safe integer cents, never a fractional-cents
  extraction:

  ```sql
  concat('$', toString(floor(round(x * 100) / 100)), '.',
         leftPad(toString(round(x * 100) % 100), 2, '0'))
  ```

  `round((x - floor(x)) * 100)` is FORBIDDEN: on x like 1893.995 the
  fraction rounds to 100 cents and renders `$1893.100`. Never
  SI-abbreviated on these tiles (`$2.88K` is forbidden); the p15 timeseries
  axis may keep `currencyUSD` since axis abbreviation is standard.
- **Currency on the p3 combined token·spend tiles** = compact K/M/B money
  matching the dashboard's Grafana-rendered currency (p8 tooltip, p46
  legend), 2 decimals with trailing zeros kept:

  ```sql
  multiIf(x >= 1000000000, concat(printf('%.2f', x / 1000000000), 'B'),
          x >= 1000000,    concat(printf('%.2f', x / 1000000), 'M'),
          x >= 1000,       concat(printf('%.2f', x / 1000), 'K'),
          printf('%.2f', x))
  ```

  The value is prefixed with `$` and joined to the compact token string by
  a middot (see Panel 3). `printf('%.2f', ...)` keeps 2 decimals
  (`1600 -> "1.60K"`); `toString(round(x, 2))` is not used here because it
  drops trailing zeros and would not read identically to Grafana's
  currency formatting.
- **Token volumes / large counts on tiles** = SQL-formatted compact
  uppercase `B`/`M`/`K`, rounded (never floored):

  ```sql
  multiIf(v >= 1000000000, concat(toString(round(v / 1000000000, 2)), 'B'),
          v >= 1000000,    concat(toString(round(v / 1000000, 2)), 'M'),
          v >= 1000,       concat(toString(round(v / 1000, 2)), 'K'),
          toString(v))
  ```

  Trailing zeros may drop (`106000` renders `106K`, `105920` renders
  `105.92K`; ClickHouse `toString` behavior, accepted 2026-09-17).
  Floor-truncated decimals are FORBIDDEN (`floor((v % 1000) / 10)` turns
  `106059` into `106.05K`; rounding gives `106.06K`). No unit word:
  Grafana's `short` unit renders "Bil"/"Mil" and is forbidden on tiles.
- **Graphs, bargauges, axes and tables (rendered values)** = set the Grafana
  `unit` and let Grafana abbreviate: `short` for large counts (K / Mil / Bil),
  the domain unit otherwise (`bytes`, `s`, `ms`, `Bps`, `percent`, ...). The
  `short` unit is allowed here (e.g. p8 treemap tile token sizes and p46
  provider legend values) precisely because these are not exact-value stat
  tiles.
- **Precision**: measured rates, costs, speeds and scores display 2 decimals
  (display `decimals: 2` + SQL `round(x, 2)`); raw counts stay integers.
- **Stat panels with string fields** must use `textMode: value_and_name`
  (string fields do not render under `textMode: auto` reduce) and
  `reduceOptions.fields: "/./"` (an empty field filter restricts the
  reducer to numeric fields and renders "No data" for string values);
   `reduceOptions.fields` regexes must match post-override display names -
   prefer `/./` when overrides rename fields.

### 2.5 Per-model panels are colorless

Per-model panels render without per-model identity colors: every tile/bar takes
the single brand color `#247ba0`. The former palette/rank system
(`llm_gateway.model_palette` + `llm_gateway.model_color_map`, migration
`000014_model_colors`) was retired by migration `000015_drop_model_colors`, so
the shared color map no longer exists. Per-model SQL emits only `name_str` and
`value` (no `color` column, no `rowsToFields` color handler); the p46 provider
donut instead lets Grafana `palette-classic` color its slices and shows a
legend. Panels: p8, p30, p44, p37, p10.

## 3. Template Variables

Shared variables identical across all 5 dashboards (the experience dashboard
adds its local `include_local` toggle):

| Variable | Query |
|----------|-------|
| `api_key` | `SELECT k AS __text, k AS __value FROM (SELECT DISTINCT coalesce(nullIf(key_id,''), nullIf(api_key_id,''), 'unknown') AS k FROM llm_gateway.request_log) ORDER BY k` |
| `model` | `SELECT DISTINCT model FROM (SELECT model FROM llm_gateway.request_log WHERE model != '' UNION ALL SELECT model FROM llm_gateway.usage_log WHERE model != '') ORDER BY model` |

No `allValue`; Grafana expands `${var:singlequote}` natively.

## 4. Gateway Cost & Usage

### Panel 3: Token Usage by Category (stat, CH, grid x:0 y:0 w:12 h:12)

Single query (refId A) with a `WITH totals AS (...)` CTE over
`llm_gateway.usage_log` computing `total_tok`, `input_tok`
(`prompt_tokens - cached_tokens`), `cached_tok`, `output_tok`
(`completion_tokens - reasoning_tokens`), `reasoning_tok`, and `sum(cost)`.
Period averages are **run-rate projections**, not per-bucket means: a
`runrate` CTE computes `elapsed_days = greatest(dateDiff('second',
$__fromTime, $__toTime) / 86400, 1)` and
`days_in_month = toDayOfMonth(toLastDayOfMonth(toDate($__toTime)))`
(`toDaysInMonth()` does not exist in ClickHouse 24.8), then an `avgs` CTE
projects the whole-range total: monthly `total / elapsed_days * days_in_month`,
weekly `total / elapsed_days * 7`, daily `total / elapsed_days`. Because
`$__fromTime`/`$__toTime` are Grafana range macros, those lines carry
`-- noqa: LXR` for the SQLFluff lexer. Emits 8 string columns:
`"Input Tokens"`, `"Cached Tokens"`, `"Output Tokens"`, `"Reasoning Tokens"`
(compact uppercase `B`/`M`/`K` `multiIf` strings, e.g. `9.18B`), then
`"Total"`, `"Monthly Average"`, `"Weekly Average"`, `"Daily Average"`, each
formatted as compact tokens for the quantity joined by a middot to compact
K/M/B spend: `"12B · $3.89K"` (`"4.1B · $1.30K"` for the averages). The spend
side mirrors the dashboard's Grafana-rendered currency (p8 tooltip, p46
legend) via `multiIf(x >= 1e9 -> 'B', >= 1e6 -> 'M', >= 1e3 -> 'K', else '')`
around `printf('%.2f', ...)`, so large sums abbreviate (`$4.44K`) and cents
keep 2 decimals (`printf` pads; `toString(round(x, 2))` would drop trailing
zeros). Colors (byName): the four token categories
form a cool hue ramp - Input cerulean, Cached teal, Output celadon, Reasoning
light yellow - Total takes bronze, and the three period averages form a
neutral ramp - Monthly charcoal, Weekly grey, Daily cream. No two tiles share
a color. Panel contract (FR-7.4):
`reduceOptions.fields` must be `/./`: Grafana matches that regex against
post-override display names, which no longer contain "Tokens"/"Cost"; string
fields only render with `textMode: value_and_name`.

### Panel 15: Cost Over Time (timeseries, CH, grid x:0 y:12 w:24 h:8)

```sql
SELECT toStartOfDay(timestamp) as time,
       round(sum(cost), 2) as "Cost ($)"
FROM llm_gateway.usage_log
WHERE $__timeFilter(timestamp)
  AND coalesce(nullIf(key_id,''), nullIf(api_key_id,''), 'unknown') IN (${api_key:singlequote})
  AND model IN (${model:singlequote})
GROUP BY time ORDER BY time
```

One bar per day for the whole filtered range. The selected models and keys are
**additive**: each bar is that day's total spend across everything filtered in,
so the sum over the range equals total spend. Bars (`drawStyle: bars`), legend
table with `sum`, tooltip `single`.

### Panel 8: Model Distribution (treemap, CH, grid x:12 y:0 w:12 h:12)

```sql
WITH per_model AS (
  SELECT model, toInt64(sum(total_tokens)) AS tokens, sum(cost) AS cost
  FROM llm_gateway.usage_log
  WHERE $__timeFilter(timestamp) AND model != ''
    AND coalesce(...) IN (${api_key:singlequote}) AND model IN (${model:singlequote})
  GROUP BY model ORDER BY tokens DESC LIMIT 20
)
SELECT model, tokens, round(cost, 2) AS cost
FROM per_model ORDER BY tokens DESC
```

Rendered by the in-repo `gateway-treemap` plugin
(`res/grafana-plugins/gateway-treemap`, unsigned, bind-mounted to
`/var/lib/grafana/plugins/gateway-treemap` and allowed through
`GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS`). It is a hand-written AMD panel
(no bundler; `build.sh` concatenates `src/constraints.js` + `src/face.js` +
`src/panel.js` into `dist/module.js`) that keeps the treemap layout but adds a
measured tile face, templated tooltips and min/max tile-area constraints. Each tile is one model:
`textField: model` labels it, `sizeField: tokens` sets its area, and
`colorField: ""` with `defaultColor: #247ba0` fills every tile with the single
brand color. The tooltip is templated and carries the model's spend via
`{{fields.cost}}` plus `{{percent}}`.
`minTileArea: 1200` merges models below that pixel area into one overflow tile
(`otherLabel: "Other models"`) so no model collapses to an unreadable sliver;
`maxTileArea: 60000` caps a dominant model and redistributes the freed area.
The tile face is built in, not templated: percent share (largest, thin `300`),
name, then token volume. A hidden probe copy of the three lines is measured in
a `useLayoutEffect` after the tiles are laid out, and `lineFit` drops lines that
do not fit - percent if the height cannot hold all three, name if it cannot
hold name+value, name again if it is wider than the tile (value always shows).
Font size is auto (`autoFontSize: true`, `minFontSize: 8` / `maxFontSize: 22`):
the panel interpolates across the actual tiles on `cbrt(area)` (a cube-root /
volume-like scale) so a 4x-area tile is ~1.59x larger and the top tiles do not
flatten to the same size; the percent line is `1.5x` and the value `0.9x` the
base, with scaled spacing (`0.28x` base) between the percent and name lines. Tile fill ramps from the neutral brand grey `#50514f` on the smallest tile
to `#247ba0` on the largest so size reads as saturation.
`tokens` renders with unit `short`; `cost` is a byName override to
`currencyUSD` / decimals 2. The panel calls `useFieldConfig()` so Grafana
applies the dashboard's field config (unit/decimals/color) to its frames;
Grafana's display-value text is composed with its `prefix`/`suffix` (so
billions read `3.90 Bil`, not `3.90`). This panel queries `usage_log` directly
(no ASOF join); `usage_log.model` is authoritative. Tiles are colorless -
per-model identity colors (retired, §2.5) never applied here.

Layout (2026-09-21): p3 keeps horizontal tiles (`maxPerRow: 4`, w:12 h:12) so
the four category tiles fill the top row; the bottom row is Total (carrying a
per-field `textSize` override, title 14 / value 30) plus the three period
averages; p8 sits at x:12 w:12 h:12 beside p3, p15 at y:12 w:24 h:8; p46
(donut, with legend) fills the bottom row at y:20 w:24 h:8.

### Panel 46: Provider Breakdown ($) (piechart, CH, grid x:0 y:20 w:24 h:8)

```sql
WITH per_provider AS (
  SELECT coalesce(nullIf(provider_id,''),'unknown') AS provider,
         count() AS requests, toInt64(sum(total_tokens)) AS tokens, sum(cost) AS cost
  FROM llm_gateway.usage_log
  WHERE $__timeFilter(timestamp)
    AND coalesce(...) IN (${api_key:singlequote}) AND model IN (${model:singlequote})
  GROUP BY provider
)
SELECT concat(provider, ' · ', toString(requests), ' req · ',
              <compact tokens>, ' tok') AS name_str,
       round(cost, 2) AS value
FROM per_provider ORDER BY cost DESC
```

Spend share per provider/credential: vendor concentration at a glance. Donut
with a legend (`legend.showLegend: true`, placement right, `values: [value]`)
and no on-slice labels (`displayLabels: []`). The hover tooltip carries the
provider plus its request and token volume: `rowsToFields` maps
`name_str -> field.name` (provider + request and token volume) and
`value -> field.value`, and Grafana `palette-classic` colors the slices (no
explicit provider colors).

## 5. Gateway Operations & Health

### Panel 1: Total Requests (stat, CH, grid x:0 y:8 w:8 h:4)

`SELECT count() as total_requests FROM llm_gateway.request_log WHERE $__timeFilter(timestamp) AND <key filter>`.
Thresholds: teal / gold at 1000 / bronze at 10000.

### Panel 4: Error Rate (stat, CH, grid x:8 y:8 w:8 h:4)

`SELECT round(countIf(status >= 400) * 100.0 / count(), 2) as error_rate FROM llm_gateway.request_log WHERE $__timeFilter(timestamp) AND <key filter>`.
All 4xx + 5xx count as errors. Thresholds: teal / 1 gold / 5 coral.

### Panel 2: Active Connections (stat, Prom, grid x:16 y:8 w:8 h:4)

`apisix_nginx_http_current_connections{state="active"}` (exact label match).
Thresholds: teal / 50 gold / 100 coral.

### Panel 5: Request Rate (timeseries, Prom, grid x:0 y:12 w:12 h:8)

`sum(rate(apisix_http_status{key_hash=~"$api_key"}[5m]))`, legend `requests/s`.

### Panel 7: Status Code Breakdown (piechart, CH, grid x:12 y:12 w:12 h:8)

```sql
SELECT toString(status) as status, count() as count
FROM llm_gateway.request_log
WHERE $__timeFilter(timestamp) AND <key filter>
GROUP BY status ORDER BY status
```

Donut, `reduceOptions.values: true`, `palette-classic` + byName overrides:
200 teal, 401 gold, 429 bronze, 499 cerulean, 504 coral. Legend table (right)
with value + percent.

### Panel 13: Stream Abort Rate by Direction (timeseries, CH, grid x:0 y:20 w:12 h:8)

Two queries (A: `'Client aborted'`, B: `'Provider aborted'`), each:
`sum(if(aborted = N, 1, 0)) * 100.0 / count()` grouped by minute over
`is_stream = 1`. Field min 0 / max 100. Colors: client coral, provider gold.

### Panel 14: Stream Status (timeseries, CH, grid x:12 y:20 w:12 h:8)

Three queries (A/B/C: completed `aborted=0`, client `=1`, provider `=2`),
each `sum(if(aborted = N, 1, 0))` grouped by minute over `is_stream = 1`.
Stacked bars. Colors: completed teal, client coral, provider gold.

### Panel 9: Latency p50/p95/p99 (timeseries, Prom, grid x:0 y:28 w:12 h:8)

Three queries: `histogram_quantile(0.NN, sum by (le) (rate(apisix_http_latency_bucket{key_hash=~"$api_key"}[5m]))) * 1000`,
legends `p50`/`p95`/`p99`, unit ms. Colors: p50 teal, p95 gold, p99 coral.

### Panel 10: Response Time p50 by Model (bargauge, CH, grid x:12 y:20 w:12 h:8)

```sql
SELECT u.model AS name_str,
       quantile(0.5)(r.upstream_response_time_s) AS value
FROM llm_gateway.request_log r
ASOF LEFT JOIN llm_gateway.usage_log u
  ON r.request_id = u.request_id AND r.timestamp >= u.timestamp
WHERE $__timeFilter(r.timestamp) AND r.upstream_response_time_s > 0
  AND u.model != '' AND <key filter on r> AND u.model IN (${model:singlequote})
GROUP BY u.model ORDER BY value DESC LIMIT 20
```

The join key is `request_id` (see OPEN-ISSUES.md for residual correctness
caveats). Median wall time (p50), not mean. Unit seconds; horizontal gradient
bars in a single brand color (colorless, §2.5) via `rowsToFields`.

### Panel 11: Bandwidth In / Out (timeseries, Prom, grid x:0 y:36 w:12 h:8)

`sum(rate(apisix_bandwidth{key_hash=~"$api_key",type="ingress"}[5m]))` and the
same for `type="egress"`; legends `ingress`/`egress`; unit Bps. Colors:
ingress cerulean, egress celadon.

### Panel 12: Shared Dict Memory Usage (timeseries, Prom, grid x:0 y:44 w:24 h:8)

`(1 - apisix_shared_dict_free_space_bytes{name="key_cache"} / apisix_shared_dict_capacity_bytes{name="key_cache"}) * 100`
and identically for `name="redact_state"`. Exact label matches, min 0 / max
100, stepAfter interpolation. Colors: key_cache teal, redact_state bronze.

### Panel 50: Storage Growth (timeseries + stat, CH, grid x:0 y:52 w:24 h:8)

Bytes-on-disk per `llm_gateway` table over time:
`SELECT sum(bytes_on_disk) FROM system.parts WHERE database = 'llm_gateway' GROUP BY table`
plus a free-space stat from `system.disks` (`free_space_bytes` /
`total_space_bytes`). Runs under the `grafana_ro` grants (system.parts,
system.disks, system.tables only  -  REQ-SECURITY-HARDENING FR-2.1). A unified
alert rule on the stat fires below 20% free or on anomalous growth
(REQ-SECURITY-HARDENING FR-4.3). No `request_bodies` reference.

Datasource identity: the ClickHouse datasource authenticates as `grafana_ro`
with `secureJsonData.password` from `$CH_GRAFANA_RO_PASSWORD` in
[`conf/grafana/provisioning/datasources/datasources.yml`](../../conf/grafana/provisioning/datasources/datasources.yml);
no datasource ever carries `ops_admin` credentials (SPEC-SECURITY-HARDENING §8).

## 6. Gateway Cost Leaderboard

Four stat panels in a 2x2 grid (2026-09-17): top row clients-left /
models-right (p20 x:0 y:0 w:12, p21 x:12 y:0 w:12), bottom row the 4-10
runner-ups in the same arrangement (p22 x:0 y:8 w:12, p23 x:12 y:8 w:12).
Podium panels use enlarged fixed `textSize` (title 22 / value 44,
`maxPerRow: 3`); runner-ups title 16 / value 22, `maxPerRow: 4`. Rank and
medal color are computed in SQL via `row_number() OVER ()`.

### Panel 20: Top Clients by Cost & Tokens (Top 3) (stat, CH, grid x:0 y:0 w:12 h:8)

`WITH ranked AS (...)` groups `usage_log` by normalized client key, orders by
`total_cost DESC LIMIT 100`, then emits `name_str` (`"N. client - 5.76B"` -
rank, entity, compact uppercase token volume via `multiIf` thresholds
`>= 1e9 -> 'B'`, `>= 1e6 -> 'M'`, `>= 1e3 -> 'K'`, 2 decimals, no unit word),
`value_str` (exact currency string `"$1893.31"`: the rollover-safe
floor/cents formula of section 2.4, standalone money tile), and `Color` (`#C9A44C` rank 1, `#A8A9AD` rank 2,
`#B07A3C` rank 3, `#FFFFFF` ranks 4-10), `LIMIT 3`. The `rowsToFields`
transformation maps `name_str -> field.name`, `value_str -> field.value`,
`Color -> color`.

### Panel 22: Top Clients by Cost & Tokens (4-10) (stat, CH, grid x:0 y:8 w:12 h:8)

Identical CTE and shape, `LIMIT 7 OFFSET 3`: rows 4-10 render in the same
rank/color scheme (all fall through to `#FFFFFF`).

### Panel 21: Top Models by Cost & Tokens (Top 3) (stat, CH, grid x:12 y:0 w:12 h:8)

Same shape as panel 20, grouped by `model` (excluding empty model), ranked by
cost, same medal color scheme, `LIMIT 3`.

### Panel 23: Top Models by Cost & Tokens (4-10) (stat, CH, grid x:12 y:8 w:12 h:8)

Same shape as panel 22 over the models CTE: `LIMIT 7 OFFSET 3`.

## 7. Edge Cases & Decisions

- **Error rate datasource:** ClickHouse, because a hardcoded Prometheus `[5m]`
  window ignores the dashboard time range and counters reset on restart.
- **`sum(rate(...))` on p5/p11:** collapses per-`key_hash` series into one
  gateway-level line; bare `rate()` would draw one line per key.
- **p7 `reduceOptions.values: true`:** required so each status-code row becomes
  its own pie slice.
- **Leaderboard LIMIT 100 / LIMIT 3+7:** inner query caps candidates, the
  podium/runner-up split (`LIMIT 3` and `LIMIT 7 OFFSET 3`) lets Grafana
  render top-3 tiles enlarged without shrinking ranks 4-10.

## 8. File Map

| File | Purpose | Key Changes |
|------|---------|-------------|
| `conf/grafana/dashboards/gateway-cost-usage.json` | Cost & Usage dashboard | panels 3, 15, 8, 46 |
| `conf/grafana/dashboards/gateway-ops-health.json` | Ops & Health dashboard | 11 panels, 6 CH + 5 Prom |
| `conf/grafana/dashboards/gateway-cost-leaderboard.json` | Leaderboard | panels 20-23, SQL-computed ranks |
| `tests/config/test_dashboard_*.sh` | Structural dashboard tests | one per dashboard |
| `tests/config/dashboard_assert.sh` | Shared assertion helpers | rawSql-only, refId, colors |
| `tests/integration/test_dashboard_queries.sh` | Live query tests | consistency invariants |

## 9. Implementation Status

| Component | Status | Evidence |
|-----------|--------|----------|
| Cost & Usage dashboard (4 panels) | Implemented | gateway-cost-usage.json |
| Ops & Health dashboard (11 panels) | Implemented | gateway-ops-health.json |
| Cost Leaderboard (2 panels) | Implemented | gateway-cost-leaderboard.json |
| Per-model panels colorless (§2.5) | Implemented | single brand color `#247ba0` on p8/p10/p30/p44/p37; model-color VIEWs dropped by migration `000015_drop_model_colors` |
| Template variables (api_key, model) | Implemented | templating block in all 3 JSONs |
| Structural tests | Implemented | tests/config/test_dashboard_*.sh |
| Cross-table join correctness | Partial | p10 uses `request_id` join; residual issues tracked in architecture/OPEN-ISSUES.md |
