# SPEC-DASHBOARD: Gateway Grafana Dashboards Implementation

**Date:** 2026-07-17
**Status:** Active
**Type:** Specification
**Requirements:** [REQ-DASHBOARD](../requirements/REQ-DASHBOARD.md)

> Panel-by-panel query specification for the 3 gateway dashboards (16 panels).
> All queries below are transcribed from the deployed dashboard JSONs and
> verified against them. Known cross-table data-quality issues are tracked in
> [architecture/OPEN-ISSUES.md](../architecture/OPEN-ISSUES.md).

---

**Cross-references:**
- [REQ-DASHBOARD](../requirements/REQ-DASHBOARD.md): requirements
- [architecture/OPEN-ISSUES.md](../architecture/OPEN-ISSUES.md): known issues audit
- [`conf/grafana/dashboards/gateway-cost-usage.json`](../../conf/grafana/dashboards/gateway-cost-usage.json): uid `gateway-cost-usage` (panels 3, 15, 8)
- [`conf/grafana/dashboards/gateway-ops-health.json`](../../conf/grafana/dashboards/gateway-ops-health.json): uid `gateway-ops-health` (panels 1, 2, 4, 5, 7, 13, 14, 9, 10, 11, 12)
- [`conf/grafana/dashboards/gateway-cost-leaderboard.json`](../../conf/grafana/dashboards/gateway-cost-leaderboard.json): uid `gateway-cost-leaderboard` (panels 20, 21)

---

## 1. Overview

| Dashboard | UID | Panels | Datasources |
|-----------|-----|--------|-------------|
| Gateway Cost & Usage | `gateway-cost-usage` | 3 (stat), 15 (timeseries), 8 (bargauge) | 3 CH |
| Gateway Operations & Health | `gateway-ops-health` | 1, 2, 4, 5, 7, 13, 14, 9, 10, 11, 12 | 6 CH + 5 Prom |
| Gateway Cost Leaderboard | `gateway-cost-leaderboard` | 20, 21 (stat, 10 ranked tiles each) | 2 CH |

All dashboards: time `now-7d`→`now`, refresh `5s`.

## 2. Architectural Principles

### 2.1 ClickHouse for history, Prometheus for now

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

## 3. Template Variables

Identical across all 3 dashboards:

| Variable | Query |
|----------|-------|
| `api_key` | `SELECT k AS __text, k AS __value FROM (SELECT DISTINCT coalesce(nullIf(key_id,''), nullIf(api_key_id,''), 'unknown') AS k FROM llm_gateway.request_log) ORDER BY k` |
| `model` | `SELECT DISTINCT model FROM (SELECT model FROM llm_gateway.request_log WHERE model != '' UNION ALL SELECT model FROM llm_gateway.usage_log WHERE model != '') ORDER BY model` |

No `allValue`; Grafana expands `${var:singlequote}` natively.

## 4. Gateway Cost & Usage

### Panel 3: Token Usage by Category (stat, CH, grid x:0 y:0 w:12 h:8)

Single query (refId A) with a `WITH totals AS (...)` CTE over
`llm_gateway.usage_log` computing `total_tok`, `input_tok`
(`prompt_tokens - cached_tokens`), `cached_tok`, `output_tok`
(`completion_tokens - reasoning_tokens`), `reasoning_tok`, and `total_cost`,
then emitting 5 aliased string columns (`Total`, `Input`, `Cached`, `Output`,
`Reasoning`) formatted via `multiIf` as `"1.2 Mil ($0.35)"`. Cost share per
category: `round(total_cost * <cat>_tok / nullIf(total_tok, 0), 2)`.
Colors (byName): Total teal, Input cerulean, Cached muted-teal, Output gold,
Reasoning coral.

### Panel 15: Cost Over Time by Model (timeseries, CH, grid x:12 y:0 w:12 h:8)

```sql
SELECT toStartOfMinute(timestamp) as time, model as label,
       round(sum(cost), 6) as cost
FROM llm_gateway.usage_log
WHERE $__timeFilter(timestamp)
  AND coalesce(nullIf(key_id,''), nullIf(api_key_id,''), 'unknown') IN (${api_key:singlequote})
  AND model IN (${model:singlequote})
GROUP BY time, model ORDER BY time, label
```

Stacked area (`stacking.mode: normal`), sum legend table at bottom.

### Panel 8: Model Distribution (bargauge, CH, grid x:0 y:8 w:24 h:8)

```sql
SELECT model, count() as requests
FROM llm_gateway.usage_log
WHERE $__timeFilter(timestamp) AND model != ''
  AND coalesce(nullIf(key_id,''), nullIf(api_key_id,''), 'unknown') IN (${api_key:singlequote})
  AND model IN (${model:singlequote})
GROUP BY model ORDER BY requests DESC LIMIT 20
```

Note: this panel queries `usage_log` directly (no ASOF join); `usage_log.model`
is authoritative. Horizontal gradient bars, `palette-classic`, `showUnfilled`.

## 5. Gateway Operations & Health

### Panel 1: Total Requests (stat, CH, grid x:0 y:8 w:8 h:4)

`SELECT count() as total_requests FROM llm_gateway.request_log WHERE $__timeFilter(timestamp) AND <key filter>`.
Thresholds: teal / gold at 1000 / bronze at 10000.

### Panel 4: Error Rate % (stat, CH, grid x:8 y:8 w:8 h:4)

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

### Panel 10: Avg Response Time by Model (bargauge, CH, grid x:12 y:20 w:12 h:8)

```sql
SELECT u.model, avg(r.upstream_response_time_s) as avg_latency
FROM llm_gateway.request_log r
ASOF LEFT JOIN llm_gateway.usage_log u
  ON r.request_id = u.request_id AND r.timestamp >= u.timestamp
WHERE $__timeFilter(r.timestamp) AND r.upstream_response_time_s > 0
  AND u.model != '' AND <key filter on r> AND u.model IN (${model:singlequote})
GROUP BY u.model ORDER BY avg_latency DESC LIMIT 20
```

The join key is `request_id` (see OPEN-ISSUES.md for residual correctness
caveats). Unit seconds; horizontal gradient bars.

### Panel 11: Bandwidth In / Out (timeseries, Prom, grid x:0 y:36 w:12 h:8)

`sum(rate(apisix_bandwidth{key_hash=~"$api_key",type="ingress"}[5m]))` and the
same for `type="egress"`; legends `ingress`/`egress`; unit Bps. Colors:
ingress cerulean, egress celadon.

### Panel 12: Shared Dict Memory Usage (timeseries, Prom, grid x:0 y:44 w:24 h:8)

`(1 - apisix_shared_dict_free_space_bytes{name="key_cache"} / apisix_shared_dict_capacity_bytes{name="key_cache"}) * 100`
and identically for `name="redact_state"`. Exact label matches, min 0 / max
100, stepAfter interpolation. Colors: key_cache teal, redact_state bronze.

## 6. Gateway Cost Leaderboard

Both panels are stat panels rendering 10 ranked tiles; rank and medal color
are computed in SQL via `row_number() OVER ()`.

### Panel 20: Top Clients by Cost & Tokens (stat, CH, grid x:0 y:0 w:24 h:16)

`WITH ranked AS (...)` groups `usage_log` by normalized client key, orders by
`total_cost DESC LIMIT 100`, then emits `name_str` (`"N. client"`), `value_str`
(`"1.2 Mil ($34.56)"`), and `Color` (`#C9A44C` rank 1, `#A8A9AD` rank 2,
`#B07A3C` rank 3, `#FFFFFF` ranks 4-10), `LIMIT 10`.

### Panel 21: Top Models by Cost & Tokens (stat, CH, grid x:0 y:16 w:24 h:16)

Same shape as panel 20, grouped by `model` (excluding empty model), ranked by
cost, same medal color scheme.

## 7. Edge Cases & Decisions

- **Error rate datasource:** ClickHouse, because a hardcoded Prometheus `[5m]`
  window ignores the dashboard time range and counters reset on restart.
- **`sum(rate(...))` on p5/p11:** collapses per-`key_hash` series into one
  gateway-level line; bare `rate()` would draw one line per key.
- **p7 `reduceOptions.values: true`:** required so each status-code row becomes
  its own pie slice.
- **Leaderboard LIMIT 100 / LIMIT 10:** inner query caps candidates, outer
  limits rendered tiles.

## 8. File Map

| File | Purpose | Key Changes |
|------|---------|-------------|
| `conf/grafana/dashboards/gateway-cost-usage.json` | Cost & Usage dashboard | panels 3, 15, 8 |
| `conf/grafana/dashboards/gateway-ops-health.json` | Ops & Health dashboard | 11 panels, 6 CH + 5 Prom |
| `conf/grafana/dashboards/gateway-cost-leaderboard.json` | Leaderboard | panels 20, 21, SQL-computed ranks |
| `tests/config/test_dashboard_*.sh` | Structural dashboard tests | one per dashboard |
| `tests/config/dashboard_assert.sh` | Shared assertion helpers | rawSql-only, refId, colors |
| `tests/integration/test_dashboard_queries.sh` | Live query tests | consistency invariants |

## 9. Implementation Status

| Component | Status | Evidence |
|-----------|--------|----------|
| Cost & Usage dashboard (3 panels) | Implemented | gateway-cost-usage.json |
| Ops & Health dashboard (11 panels) | Implemented | gateway-ops-health.json |
| Cost Leaderboard (2 panels) | Implemented | gateway-cost-leaderboard.json |
| Template variables (api_key, model) | Implemented | templating block in all 3 JSONs |
| Structural tests | Implemented | tests/config/test_dashboard_*.sh |
| Cross-table join correctness | Partial | p10 uses `request_id` join; residual issues tracked in architecture/OPEN-ISSUES.md |
