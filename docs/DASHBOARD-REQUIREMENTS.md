# Dashboard Requirements: Gateway Dashboards

> **KNOWN ISSUES (2026-07-09):**
> - All panels using `ASOF LEFT JOIN ON r.key_id = u.key_id AND r.timestamp >= u.timestamp`
>   (Panels 8, 10) are **probabilistically wrong** - under concurrent requests
>   per key, the join matches the wrong `usage_log` row. The join key is not
>   unique per request.
> - The `event_id` JOIN path (`request_log.event_id = usage_log.event_id`) does
>   **not work** historically - `usage_log.event_id` is always
>   `relay-opencode_0` due to broken `start_time` generation.
> - `request_log.model` and `usage_log.model` differ for the same request
>   (e.g., `frank/GLM-5.2` vs `glm-5.2`), so the model variable UNION produces
>   duplicate entries.
> - `prompt_tokens`/`completion_tokens` differ between tables for SSE requests
>   (`request_log` parses JSON, always 0; `usage_log` parses SSE, accurate).
>   Cross-table comparisons are misleading.
> - The `billing_ledger` table that several panels reference as a future data
>   source has zero rows - no pipeline writes to it.
>
> All panels display data from their respective sources correctly in isolation;
> the cross-table JOINs are where correctness breaks down. See
> `docs/ARCHITECTURE.md` head for full audit.

This document specifies the purpose, theory, and correctness criteria for every
panel across the 3 gateway dashboards:

| Dashboard | File | UID | Panels |
|-----------|------|-----|--------|
| Gateway Cost & Usage | `conf/grafana/dashboards/gateway-cost-usage.json` | `gateway-cost-usage` | p3, p8, p15 (all ClickHouse) |
| Gateway Operations & Health | `conf/grafana/dashboards/gateway-ops-health.json` | `gateway-ops-health` | p1, p2, p4, p5, p7, p9, p10, p11, p12, p13, p14 (6 CH + 5 Prom) |
| Gateway Cost Leaderboard | `conf/grafana/dashboards/gateway-cost-leaderboard.json` | `gateway-cost-leaderboard` | p20, p21 (ClickHouse stat panels, 10 ranked tiles each) |

It is the authoritative spec: tests verify against this document, not against
the JSON structure alone.

## 1. Purpose

The dashboard gives the gateway operator a real-time and historical view of
LLM gateway traffic, cost, latency, errors, and internal health. It answers
five operational questions:

1. **How much are we spending?** (token usage, cost over time)
2. **Is the gateway up and handling traffic?** (request rate, total requests,
   active connections)
3. **Are users seeing errors?** (error rate, status code breakdown)
4. **Is performance acceptable?** (latency percentiles, avg latency by model,
   bandwidth, stream abort rates)
5. **Is the gateway itself healthy?** (shared dict memory, stream status)

## 2. Data Sources

| Source | UID | Used For | Why |
|--------|-----|----------|-----|
| ClickHouse | `clickhouse` | Token usage, cost, model distribution, avg latency, stream stats, error rate, total requests, status code breakdown | Long-term storage with `$__timeFilter` macro that respects the dashboard time range selector. Authoritative for billing, usage, and request-level analytics. |
| Prometheus | `prometheus` | Active connections, request rate, latency percentiles, bandwidth, shared dict memory | Real-time counters and histograms from APISIX. Ideal for instantaneous rates and percentiles via `rate()` and `histogram_quantile()`. |

### Why Error Rate uses ClickHouse, not Prometheus

The previous implementation used Prometheus `rate(apisix_http_status{code=~"5.."}[5m])`.
The `[5m]` window is hardcoded and does NOT respect the dashboard time range.
If no 5xx occurred in the last 5 minutes, the panel shows 0% even when the
24h window contains 4 server errors. ClickHouse `request_log` with
`$__timeFilter(timestamp)` respects the dashboard time range and provides the
authoritative error count.

### Why Total Requests uses ClickHouse, not Prometheus

Prometheus `apisix_http_status` is a per-process counter that resets to 0
on container restart. A stack redeploy would erase the cumulative total.
ClickHouse `request_log` is persistent and provides the authoritative
lifetime request count for the selected key filter.

### Why Status Code Breakdown uses ClickHouse, not Prometheus

Prometheus `sum by (code) (apisix_http_status)` only counts requests since
the last APISIX restart. ClickHouse `request_log` contains the complete
history and respects the dashboard time range selector.

## 3. Global Filters

Two template variables filter every panel query:

| Variable | Datasource | Query | All Behavior |
|----------|------------|-------|--------------|
| `api_key` | ClickHouse | `SELECT DISTINCT coalesce(nullIf(key_id,''), nullIf(api_key_id,''), 'unknown') FROM request_log` | No `allValue` set. Grafana expands `${api_key:singlequote}` to all values when "All" is selected. |
| `model` | ClickHouse | `SELECT DISTINCT model FROM (request_log UNION ALL usage_log) WHERE model != ''` | No `allValue`. UNIONs both tables so all models appear. |

Time range: default `now-7d` to `now`, refresh every 5 seconds.

The key identity filter uses `coalesce(nullIf(key_id,''), nullIf(api_key_id,''), 'unknown')`
to normalize the key field across both tables (some rows use `key_id`, others
`api_key_id`). This ensures a single key filter works consistently.

## 4. Panel Specifications

### Panel 3: Token Usage by Category

| Field | Value |
|-------|-------|
| ID | 3 |
| Type | stat |
| Datasource | ClickHouse |
| Grid | x:0 y:0 w:12 h:8 |
| Unit | short (custom formatted string) |

**Purpose:** Show total token consumption broken down by category (Input,
Cached, Output, Reasoning) with per-category cost attribution.

**Theory:** Token costs vary by category. Cached tokens are cheaper than
input tokens, which are cheaper than output tokens. Reasoning tokens (for
extended-thinking models) are the most expensive. Showing the split lets
the operator understand the cost driver: a model with high reasoning token
usage will cost more than one with high cached token usage, even at the same
total token count.

**Query:** 5 separate ClickHouse table queries (refId A-E), each returning
a single row with a formatted string like `"1.2 Mil ($0.35)"`. The format
uses `multiIf` to display millions as "Mil", thousands as "K", and raw count
otherwise. Each tile shows the token count and its proportional cost share:
`round(total_cost * category_tok / nullIf(total_tok, 0), 2)`.

**Column aliases:** Each query uses a unique alias (`Total`, `Input`,
`Cached`, `Output`, `Reasoning`) so Grafana's `byName` override matcher can
assign distinct colors. Using the same alias (the old `as val`) caused all
5 overrides to collide, making every tile the same color.

**Color overrides (byName matchers):**
- Total: teal `#70c1b3`
- Input (uncached): cerulean `#247ba0`
- Cached: muted-teal `#8cada7`
- Output (non-reasoning): gold `#ffe066`
- Reasoning: coral `#f25f5c`

**Correctness criteria:**
- 5 unique column aliases (no duplicates)
- 5 unique byName override matchers matching the aliases
- `total = input + cached + output + reasoning` (token conservation)
- All token counts >= 0
- Each tile displays as `"NN (Mil|K)? ($X.XX)"` format
- `format: "table"`, `queryType: "table"` on every target
- NO `meta`, `editorType`, or `pluginVersion` keys (these trigger builder mode)

---

### Panel 15: Cost Over Time by Model

| Field | Value |
|-------|-------|
| ID | 15 |
| Type | timeseries |
| Datasource | ClickHouse |
| Grid | x:12 y:0 w:12 h:8 |
| Unit | currencyUSD |

**Purpose:** Show cumulative cost per model over the selected time range,
stacked by model.

**Theory:** Cost is the primary business metric. A stacked area chart per
model lets the operator see both the total spend and the per-model
contribution. The legend table at the bottom shows the sum for each model,
enabling quick comparison. This panel answers "which models are costing
the most?" without requiring a separate report.

**Query:** Single ClickHouse timeseries query. Groups by `toStartOfMinute(timestamp)`
and `model`, sums `cost` rounded to 6 decimal places. Uses `format: "timeseries"`
with `timeColumn: "time"`.

**Rendering:** Stacked area chart (`stacking.mode: "normal"`), smooth lines,
30% fill opacity, spans nulls (connects gaps). Legend is a table at the
bottom showing `sum` per series.

**Correctness criteria:**
- `format: "timeseries"`, `timeColumn: "time"`
- Cost values >= 0
- Sum of all per-minute cost values = total cost (cross-query consistency)
- NO `meta`, `editorType`, or `pluginVersion` keys

---

### Panel 1: Total Requests

| Field | Value |
|-------|-------|
| ID | 1 |
| Type | stat |
| Datasource | ClickHouse |
| Grid | x:0 y:8 w:8 h:4 |
| Unit | req |

**Purpose:** Show the total number of HTTP requests processed by the gateway
for the selected key filter over the dashboard time range.

**Theory:** A single large number gives an instant sense of traffic volume.
ClickHouse `request_log` with `$__timeFilter` provides a persistent count
that survives container restarts (unlike Prometheus counters, which reset
on redeploy). Thresholds provide visual cues: under 1000 is normal
(teal), 1000-10000 is elevated (gold), over 10000 is high (bronze).

**Query:** `SELECT count() as total_requests FROM llm_gateway.request_log WHERE $__timeFilter(timestamp) AND coalesce(nullIf(key_id,''), nullIf(api_key_id,''), 'unknown') IN (${api_key:singlequote})`

**Why ClickHouse, not Prometheus:** The Prometheus counter
`apisix_http_status` resets to 0 on container restart. A stack redeploy
would erase the cumulative total, making the panel show 0 after every
restart. ClickHouse `request_log` is persistent and respects the
dashboard time range selector.

**Thresholds:** null/teal, 1000/gold, 10000/bronze

**Correctness criteria:**
- Value >= 0
- Single-valued stat (no multi-series)
- Thresholds: null/teal, 1000/gold, 10000/bronze
- Datasource is ClickHouse (NOT Prometheus)
- Uses `$__timeFilter` and `format: "table"`, `queryType: "table"`
- NO `meta`, `editorType`, or `pluginVersion` keys

---

### Panel 4: Error Rate %

| Field | Value |
|-------|-------|
| ID | 4 |
| Type | stat |
| Datasource | ClickHouse |
| Grid | x:8 y:8 w:8 h:4 |
| Unit | percent |

**Purpose:** Show the percentage of requests that resulted in HTTP errors
(4xx + 5xx) over the dashboard time range.

**Theory:** Error rate is the single most important health metric. A
non-zero error rate means something is wrong -- either client-side (4xx:
bad request, unauthorized, rate limited, not found) or server-side (5xx:
gateway or provider failure, timeout, unavailable). All `status >= 400`
are errors from the operator's perspective: 401 means a key is expired,
404 means a bad route, 429 means rate limiting is triggering, 500+ means
the gateway or upstream is broken. The threshold at 1% (gold) warns the
operator; at 5% (coral) the gateway is in trouble.

**Query:** `SELECT round(countIf(status >= 400) * 100.0 / count(), 2) as error_rate FROM llm_gateway.request_log WHERE $__timeFilter(timestamp) AND coalesce(nullIf(key_id,''), nullIf(api_key_id,''), 'unknown') IN (${api_key:singlequote})`

**Why ClickHouse, not Prometheus:** The old Prometheus query
`rate(apisix_http_status{code=~"5.."}[5m])` used a hardcoded 5-minute window
that ignored the dashboard time range selector. If no 5xx occurred in the
last 5 minutes, it showed 0% even when the 24h window contained server
errors. ClickHouse with `$__timeFilter` respects the selected time range,
giving the operator the true error rate for their chosen window.

**Thresholds:** null/teal (0% = healthy), 1/gold (warning), 5/coral (critical)

**Correctness criteria:**
- Value in [0, 100]
- `format: "table"`, `queryType: "table"`
- Datasource is ClickHouse (NOT Prometheus)
- Uses `$__timeFilter` and `countIf(status >= 400)` (all 4xx + 5xx errors)
- NO `meta`, `editorType`, or `pluginVersion` keys
- If there are errors (status >= 400) in the time range, value > 0

---

### Panel 2: Active Connections

| Field | Value |
|-------|-------|
| ID | 2 |
| Type | stat |
| Datasource | Prometheus |
| Grid | x:16 y:8 w:8 h:4 |
| Unit | short |

**Purpose:** Show the current number of active HTTP connections to APISIX.

**Theory:** Active connections indicate real-time load on the gateway. A
sudden spike may indicate a traffic surge or a misconfigured client
reusing connections. Thresholds: under 50 is normal (teal), 50-100 is
elevated (gold), over 100 is high (coral).

**Query:** `apisix_nginx_http_current_connections{state="active"}`

**Correctness criteria:**
- Value >= 0
- Single-valued stat
- Uses exact label match `state="active"` (not regex)

---

### Panel 5: Request Rate (req/s)

| Field | Value |
|-------|-------|
| ID | 5 |
| Type | timeseries |
| Datasource | Prometheus |
| Grid | x:0 y:12 w:12 h:8 |
| Unit | reqps |

**Purpose:** Show the per-second request rate over time.

**Theory:** The request rate timeseries shows traffic patterns: bursts,
drops, and steady-state load. The `rate()` function over a 5-minute window
smooths out per-second noise. The `sum()` aggregation collapses all key
hashes into a single line, which is what the operator wants for a
gateway-level view (per-key breakdown would be too noisy).

**Query:** `sum(rate(apisix_http_status{key_hash=~"$api_key"}[5m]))`

**Correctness criteria:**
- Uses `sum(rate(...))` (aggregation required for single series)
- `legendFormat: "requests/s"` (fixed string, not `{{label}}`)
- Value >= 0

---

### Panel 7: Status Code Breakdown

| Field | Value |
|-------|-------|
| ID | 7 |
| Type | piechart |
| Datasource | ClickHouse |
| Grid | x:12 y:12 w:12 h:8 |
| Unit | short |

**Purpose:** Show the distribution of HTTP response status codes as a donut
chart for the dashboard time range.

**Theory:** The status code breakdown reveals the health composition of
responses. A healthy gateway shows mostly 200 (teal) with small slices of
401 (gold, unauthorized) and 429 (bronze, rate limited). A large 499 slice
(cerulean, client closed) suggests slow responses. A 504 slice (coral,
gateway timeout) indicates upstream provider issues.

**Query:** `SELECT toString(status) as status, count() as count FROM llm_gateway.request_log WHERE $__timeFilter(timestamp) AND coalesce(nullIf(key_id,''), nullIf(api_key_id,''), 'unknown') IN (${api_key:singlequote}) GROUP BY status ORDER BY status`

**Why ClickHouse, not Prometheus:** Prometheus `sum by (code)
(apisix_http_status)` only counts requests since the last APISIX restart.
ClickHouse `request_log` contains the complete history and respects the
dashboard time range selector via `$__timeFilter`.

**reduceOptions:** `values: true` is required so the piechart treats each
row as a separate slice. Without it, Grafana reduces all rows to a single
value and the piechart shows one slice instead of one per status code.

**Legend:** Table on the right side, displaying both `value` and `percent`
for each status code so percentages are visible without hovering.

**Color mode:** `palette-classic` base with 5 `byName` color overrides for
expected status codes. Categorical data (status codes) needs per-value
colors, not threshold-based coloring. Thresholds apply to numeric ranges,
not discrete categories.

**Color overrides (byName matchers):**
- 200: teal `#70c1b3` (success)
- 401: gold `#ffe066` (unauthorized)
- 429: bronze `#b7990d` (rate limited)
- 499: cerulean `#247ba0` (client closed)
- 504: coral `#f25f5c` (gateway timeout)

**Correctness criteria:**
- `color.mode: "palette-classic"` (NOT "thresholds")
- >= 1 color override (per-value colors for categorical data)
- Each override uses `byName` matcher with the status code as `options`
- Override colors are brand palette
- `pieType: "donut"`, displayLabels include "name" and "percent"

---

### Panel 13: Stream Abort Rate by Direction (%)

| Field | Value |
|-------|-------|
| ID | 13 |
| Type | timeseries |
| Datasource | ClickHouse |
| Grid | x:0 y:20 w:12 h:8 |
| Unit | percent (0-100) |

**Purpose:** Show the percentage of streaming requests that were aborted,
split by who aborted (client vs provider).

**Theory:** Streaming responses can be interrupted by either the client
(disconnected, navigated away) or the provider (upstream error, timeout).
High client abort rates may indicate UI bugs or impatient users. High
provider abort rates indicate upstream instability. The `aborted` column
in `usage_log` encodes: 0=completed, 1=client-aborted, 2=provider-aborted.

**Queries:** Two ClickHouse timeseries queries (refId A, B), each computing
`sum(if(aborted = N, 1, 0)) * 100.0 / count()` grouped by minute. Only
streaming requests (`is_stream = 1`) are counted.

**Color overrides:**
- Client aborted: coral `#f25f5c`
- Provider aborted: gold `#ffe066`

**Correctness criteria:**
- Values in [0, 100]
- `format: "timeseries"`, `timeColumn: "time"`
- `min: 0`, `max: 100` on field defaults
- NO `meta`, `editorType`, or `pluginVersion` keys

---

### Panel 14: Stream Status (completed / client-aborted / provider-aborted)

| Field | Value |
|-------|-------|
| ID | 14 |
| Type | timeseries |
| Datasource | ClickHouse |
| Grid | x:12 y:20 w:12 h:8 |
| Unit | short (count) |

**Purpose:** Show the absolute count of streaming requests by completion
status, stacked over time.

**Theory:** While Panel 13 shows abort rates as percentages, Panel 14 shows
absolute counts. Both are needed: a 50% abort rate on 2 requests is less
alarming than a 10% abort rate on 1000 requests. The stacked bar chart
shows the composition and volume together.

**Queries:** Three ClickHouse timeseries queries (refId A, B, C) computing
`sum(if(aborted = N, 1, 0))` grouped by minute. Only `is_stream = 1`.

**Color overrides:**
- Completed: teal `#70c1b3`
- Client aborted: coral `#f25f5c`
- Provider aborted: gold `#ffe066`

**Correctness criteria:**
- Values >= 0
- `completed + client_aborted + provider_aborted = total_streams` (partition
  consistency)
- `format: "timeseries"`, `timeColumn: "time"`
- Stacked bars (`stacking.mode: "normal"`, `drawStyle: "bars"`)
- NO `meta`, `editorType`, or `pluginVersion` keys

---

### Panel 9: Latency p50 / p95 / p99 (ms)

| Field | Value |
|-------|-------|
| ID | 9 |
| Type | timeseries |
| Datasource | Prometheus |
| Grid | x:0 y:28 w:12 h:8 |
| Unit | ms |

**Purpose:** Show the 50th, 95th, and 99th percentile latency over time.

**Theory:** Percentiles reveal the tail behavior of response times. p50
(median) shows typical performance. p95 shows what the slowest 5% of users
experience. p99 shows the worst-case 1%. If p50 is fast but p99 is very
slow, there are occasional bad requests (possibly a specific model or large
prompt). If p50 is slow, the gateway is systematically slow. The
`histogram_quantile()` function computes these from APISIX's latency
histogram buckets. Multiply by 1000 to convert seconds to milliseconds.

**Queries:** Three Prometheus queries (refId A, B, C) using
`histogram_quantile(0.NN, sum by (le) (rate(apisix_http_latency_bucket{...}[5m]))) * 1000`

**Color overrides:**
- p50: teal `#70c1b3`
- p95: gold `#ffe066`
- p99: coral `#f25f5c`

**Correctness criteria:**
- p50 <= p95 <= p99 (percentile ordering invariant)
- Values >= 0
- 3 targets with `legendFormat: "p50"`, `"p95"`, `"p99"`

---

### Panel 10: Avg Response Time by Model

| Field | Value |
|-------|-------|
| ID | 10 |
| Type | bargauge |
| Datasource | ClickHouse |
| Grid | x:12 y:28 w:12 h:8 |
| Unit | s (seconds) |

**Purpose:** Show the average upstream response time per model as a
horizontal bar gauge.

**Theory:** Different models have different latency profiles. A
bargauge makes it easy to spot which models are slowest at a glance. The
operator can use this to decide whether to route traffic to a faster
model or investigate why a specific model is slow. Only requests with
`upstream_response_time_s > 0` are counted (zero-latency requests are
typically cached responses or errors, not real upstream calls).

**Query:** `SELECT u.model, avg(r.upstream_response_time_s) as avg_latency FROM llm_gateway.request_log r ASOF LEFT JOIN llm_gateway.usage_log u ON r.key_id = u.key_id AND r.timestamp >= u.timestamp WHERE $__timeFilter(r.timestamp) AND r.upstream_response_time_s > 0 AND u.model != '' AND coalesce(...) IN (...) AND u.model IN (...) GROUP BY u.model ORDER BY avg_latency DESC LIMIT 20`

**ASOF LEFT JOIN:** Same as Panel 8: `request_log.model` is empty for most
rows, so the model name is attached via an ASOF LEFT JOIN to `usage_log`
on `key_id + timestamp`.

**Rendering:** Horizontal gradient bars, `palette-classic` colors,
`showUnfilled: true` to show the scale.

**Correctness criteria:**
- `format: "table"`, `queryType: "table"`
- Avg latency in (0, 300) seconds (0 excluded by query filter, 300s = 5min
  timeout cap)
- Model names non-empty
- NO `meta`, `editorType`, or `pluginVersion` keys (these trigger the
  grafana-clickhouse-datasource builder mode with empty `columns: []`,
  which produces an empty query and renders nothing)

---

### Panel 11: Bandwidth In / Out (bytes/s)

| Field | Value |
|-------|-------|
| ID | 11 |
| Type | timeseries |
| Datasource | Prometheus |
| Grid | x:0 y:36 w:12 h:8 |
| Unit | Bps (bytes per second) |

**Purpose:** Show the inbound and outbound network bandwidth through the
gateway.

**Theory:** Bandwidth reveals the data volume flowing through the gateway.
Ingress (incoming requests) vs egress (outgoing responses) shows the
asymmetry: LLM responses are typically much larger than requests, so
egress should exceed ingress. A sudden egress drop may indicate that
streaming responses are being truncated. The `sum()` aggregation collapses
all key hashes into one line per direction, giving a gateway-level view.

**Queries:** Two Prometheus queries (refId A, B):
`sum(rate(apisix_bandwidth{key_hash=~"$api_key",type="ingress"}[5m]))`
`sum(rate(apisix_bandwidth{key_hash=~"$api_key",type="egress"}[5m]))`

**Why `sum(rate())`, not bare `rate()`:** Without `sum()`, `rate()` returns
one series per `key_hash` label. With 18 key hashes, this produces 36
separate lines (18 ingress + 18 egress), making the chart unreadable.
`sum()` collapses each direction to a single line.

**Color overrides:**
- ingress: cerulean `#247ba0`
- egress: celadon `#a5d0a8`

**Correctness criteria:**
- Both targets use `sum(rate(...))` (NOT bare `rate()`)
- `legendFormat: "ingress"` and `"egress"` (fixed strings)
- Values >= 0

---

### Panel 8: Model Distribution

| Field | Value |
|-------|-------|
| ID | 8 |
| Type | bargauge |
| Datasource | ClickHouse |
| Grid | x:12 y:36 w:12 h:8 |
| Unit | req (request count) |

**Purpose:** Show the request count per model as a horizontal bar gauge.

**Theory:** Model distribution reveals traffic patterns: which models are
most used, and whether traffic is balanced or concentrated. A single model
dominating may indicate a routing configuration issue or user preference.
The operator can compare this with Panel 15 (Cost Over Time) to see if the
most-used model is also the most expensive.

**Query:** `SELECT u.model, count() as requests FROM llm_gateway.request_log r ASOF LEFT JOIN llm_gateway.usage_log u ON r.key_id = u.key_id AND r.timestamp >= u.timestamp WHERE $__timeFilter(r.timestamp) AND u.model != '' AND coalesce(...) IN (...) AND u.model IN (...) GROUP BY u.model ORDER BY requests DESC LIMIT 20`

**ASOF LEFT JOIN:** The `request_log.model` column is empty for most rows
(model metadata is written to `usage_log`, not `request_log`). The ASOF
LEFT JOIN on `key_id + timestamp` matches each request_log row to the
nearest preceding usage_log row, attaching the model name. The join
condition `r.timestamp >= u.timestamp` ensures the usage_log entry was
written before the request (the model is known at request time).

**Rendering:** Horizontal gradient bars, `palette-classic` colors,
`showUnfilled: true`.

**Correctness criteria:**
- `format: "table"`, `queryType: "table"`
- Each model count > 0
- Model names non-empty
- NO `meta`, `editorType`, or `pluginVersion` keys (same builder-mode bug
  as Panel 10)

---

### Panel 12: Shared Dict Memory Usage

| Field | Value |
|-------|-------|
| ID | 12 |
| Type | timeseries |
| Datasource | Prometheus |
| Grid | x:0 y:44 w:24 h:8 |
| Unit | percent (0-100) |

**Purpose:** Show the memory usage percentage of APISIX shared dictionaries.

**Theory:** APISIX uses shared dictionaries (nginx lua_shared_dict) for
in-memory caching and state. The `key_cache` dict stores resolved API keys;
the `redact_state` dict tracks redaction state for active streams. If these
dicts fill up, the gateway will evict entries or fail to store new ones,
causing cache misses or redaction failures. Monitoring memory usage lets
the operator resize the dicts before they become full.

**Queries:** Two Prometheus queries computing
`(1 - free_space / capacity) * 100` for each dict.

**Color overrides:**
- key_cache: teal `#70c1b3`
- redact_state: bronze `#b7990d`

**Correctness criteria:**
- Values in [0, 100]
- `min: 0`, `max: 100` on field defaults
- 2 targets with exact `name="..."` label match (not regex)
- `stepAfter` line interpolation (memory usage is stepwise, not continuous)

---

## 5. Cross-Query Consistency Requirements

These invariants must hold across panels:

| Invariant | Panels | Test |
|-----------|--------|------|
| Token conservation | p3 | total = input + cached + output + reasoning |
| Stream partition | p14 | completed + client_aborted + provider_aborted = total_streams |
| Cost sum = total cost | p15 | sum(per-minute cost) = total cost (tolerance 0.01) |
| Model dist sum = total requests | p8 | sum(per-model count) = total request count |
| Single key <= all keys | p1, p3, p4 | filtered total <= unfiltered total |

## 6. Structural Requirements (All Panels)

These apply to every panel regardless of type:

1. **Required fields:** Every panel has `title`, `type`, `datasource.uid`,
   `gridPos`, and at least 1 target.
2. **refId:** Every target has a `refId`.
3. **ClickHouse targets:** Every ClickHouse target has `rawSql`.
4. **Prometheus targets:** Every Prometheus target has `expr`.
5. **No `meta`/`editorType`/`pluginVersion` on ClickHouse targets:** The
   grafana-clickhouse-datasource plugin uses `meta.builderOptions` to
   construct queries in builder mode. When `columns: []` is empty, the
   builder produces an empty query and the panel renders nothing. All
   panels must use rawSql mode (no meta block).
6. **No `$__conditionalAll` macros:** Use Grafana's built-in multi-value
   expansion instead.
7. **No `allValue` on `api_key`:** Let Grafana expand to all values
   naturally.
8. **Model variable UNIONs both tables:** `request_log` UNION ALL
   `usage_log` to capture all models.
9. **All hex colors are brand palette:** teal `#70c1b3`, cerulean
   `#247ba0`, muted-teal `#8cada7`, gold `#ffe066`, bronze `#b7990d`,
   coral `#f25f5c`, celadon `#a5d0a8`, dark `#50514f`, cream `#f2f4cb`,
   ink `#110b11`. The Cost Leaderboard (p20, p21) additionally uses a controlled
   medal/neutral accent set outside the brand palette: white `#ffffff`
   (default tile background for ranks 4-10), matte gold `#c9a44c` (rank 1),
   matte silver `#a8a9ad` (rank 2), matte bronze `#b07a3c` (rank 3).
10. **Dashboard time range:** `now-7d` to `now`, refresh `5s` (all 3 dashboards).
11. **Panel count:** 16 panels total across 3 dashboards (11 ClickHouse,
    5 Prometheus). Cost & Usage: 3 CH. Operations & Health: 6 CH + 5 Prom.
    Cost Leaderboard: 2 CH (stat panels, 10 ranked tiles each).
