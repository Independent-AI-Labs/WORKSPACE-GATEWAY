# REQ-DASHBOARD: Gateway Grafana Dashboards

**Date:** 2026-07-17
**Status:** Active
**Type:** Requirements
**Specification:** [SPEC-DASHBOARD](../specifications/SPEC-DASHBOARD.md)

> Mandates 3 Grafana dashboards (16 panels total) giving the gateway operator a
> real-time and historical view of LLM traffic, cost, latency, errors, and
> internal health. Dashboard JSON files under `conf/grafana/dashboards/` are the
> single source of truth for structure; this document owns the correctness and
> consistency requirements. Known cross-table data-quality issues are tracked in
> [architecture/OPEN-ISSUES.md](../architecture/OPEN-ISSUES.md), not here.

---

**Cross-references:**
- [SPEC-DASHBOARD](../specifications/SPEC-DASHBOARD.md): panel-by-panel query specification
- [architecture/OPEN-ISSUES.md](../architecture/OPEN-ISSUES.md): known data-quality issues (ASOF join correctness, event_id misalignment, token-count divergence)
- [`conf/grafana/dashboards/gateway-cost-usage.json`](../../conf/grafana/dashboards/gateway-cost-usage.json): Cost & Usage dashboard
- [`conf/grafana/dashboards/gateway-ops-health.json`](../../conf/grafana/dashboards/gateway-ops-health.json): Operations & Health dashboard
- [`conf/grafana/dashboards/gateway-cost-leaderboard.json`](../../conf/grafana/dashboards/gateway-cost-leaderboard.json): Cost Leaderboard dashboard

---

## 1. Purpose & Scope

### 1.1 Purpose

Answer five operational questions: (1) how much are we spending, (2) is the
gateway up and handling traffic, (3) are users seeing errors, (4) is
performance acceptable, (5) is the gateway itself healthy.

### 1.2 Scope

**This document OWNS the requirements for:**
- The 3 dashboards, their 16 panels, and their datasources
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
| FR-1.1 | The system SHALL provide exactly 3 dashboards: `gateway-cost-usage` (3 CH panels: ids 3, 15, 8), `gateway-ops-health` (11 panels: ids 1, 2, 4, 5, 7, 13, 14, 9, 10, 11, 12  -  6 CH + 5 Prom), and `gateway-cost-leaderboard` (2 CH stat panels: ids 20, 21). |
| FR-1.2 | All 3 dashboards MUST default to time range `now-7d` to `now` with a 5-second refresh. |
| FR-1.3 | Panel types MUST be: 3=stat, 15=timeseries, 8=bargauge, 1=stat, 4=stat, 2=stat, 5=timeseries, 7=piechart, 13=timeseries, 14=timeseries, 9=timeseries, 10=bargauge, 11=timeseries, 12=timeseries, 20=stat, 21=stat. |

### FR-2: Datasources

| ID | Requirement |
|----|-------------|
| FR-2.1 | Token usage, cost, model distribution, total requests, error rate, status breakdown, stream stats, and per-model latency MUST use ClickHouse so `$__timeFilter` respects the dashboard time range and data survives restarts. |
| FR-2.2 | Active connections, request rate, latency percentiles, bandwidth, and shared-dict memory MUST use Prometheus for real-time `rate()`/`histogram_quantile()` semantics. |
| FR-2.3 | Total Requests (p1), Error Rate (p4), and Status Code Breakdown (p7) MUST NOT use Prometheus counters, which reset on container restart or use hardcoded windows. |

### FR-3: Global Filters

| ID | Requirement |
|----|-------------|
| FR-3.1 | Every dashboard MUST define an `api_key` template variable from ClickHouse using `coalesce(nullIf(key_id,''), nullIf(api_key_id,''), 'unknown')` over `llm_gateway.request_log`. |
| FR-3.2 | Every dashboard MUST define a `model` template variable unioning `model` from both `request_log` and `usage_log`. |
| FR-3.3 | No template variable SHALL set `allValue`; Grafana's native multi-value expansion is used. |
| FR-3.4 | Every filtered ClickHouse query MUST filter on `${api_key:singlequote}` and (where model-scoped) `${model:singlequote}`. |

### FR-4: Panel Behavioral Requirements

| ID | Requirement |
|----|-------------|
| FR-4.1 | p3 (Token Usage by Category) MUST display Total, Input (uncached), Cached, Output (non-reasoning), and Reasoning tokens with per-category cost share, as formatted strings `"NN (Mil\|K)? ($X.XX)"`, with 5 unique column aliases and 5 unique byName color overrides. |
| FR-4.2 | p15 (Cost Over Time by Model) MUST be a stacked-area timeseries of per-model cost per minute with a sum legend table. |
| FR-4.3 | p1 (Total Requests) MUST count `request_log` rows within the time filter, with thresholds teal/gold at 1000/bronze at 10000. |
| FR-4.4 | p4 (Error Rate %) MUST compute `countIf(status >= 400) * 100 / count()` (all 4xx + 5xx), with thresholds teal/1 gold/5 coral. |
| FR-4.5 | p2 (Active Connections) MUST use `apisix_nginx_http_current_connections{state="active"}` with an exact (non-regex) label match. |
| FR-4.6 | p5 (Request Rate) MUST use `sum(rate(apisix_http_status{key_hash=~"$api_key"}[5m]))` with fixed legend `requests/s`. |
| FR-4.7 | p7 (Status Code Breakdown) MUST be a donut piechart with `reduceOptions.values: true`, `palette-classic` color mode, and byName overrides for 200/401/429/499/504. |
| FR-4.8 | p13 (Stream Abort Rate) MUST compute client-aborted (`aborted=1`) and provider-aborted (`aborted=2`) percentages over `is_stream = 1` rows, clamped to [0, 100]. |
| FR-4.9 | p14 (Stream Status) MUST show stacked absolute counts for completed/client-aborted/provider-aborted streams. |
| FR-4.10 | p9 (Latency Percentiles) MUST plot p50/p95/p99 via `histogram_quantile` over `apisix_http_latency_bucket` multiplied by 1000 (ms), with the invariant p50 <= p95 <= p99. |
| FR-4.11 | p10 (Avg Response Time by Model) MUST be a bargauge of `avg(upstream_response_time_s)` per model, excluding zero-latency rows, LIMIT 20. |
| FR-4.12 | p11 (Bandwidth) MUST use `sum(rate(apisix_bandwidth{...,type="ingress|egress"}[5m]))` (not bare `rate()`), one series per direction. |
| FR-4.13 | p8 (Model Distribution) MUST be a bargauge of request counts per model from `usage_log`, LIMIT 20. |
| FR-4.14 | p12 (Shared Dict Memory) MUST plot `(1 - free/capacity) * 100` for the `key_cache` and `redact_state` dicts with exact `name="..."` matches, clamped to [0, 100], stepAfter interpolation. |
| FR-4.15 | p20/p21 (Leaderboards) MUST each render 10 ranked tiles (top clients / top models by cost) with medal colors for ranks 1-3 and white for ranks 4-10. |

### FR-5: Cross-Query Consistency

| ID | Requirement |
|----|-------------|
| FR-5.1 | p3 token conservation: total = input + cached + output + reasoning. |
| FR-5.2 | p14 stream partition: completed + client_aborted + provider_aborted = total streams. |
| FR-5.3 | p15: sum of per-minute cost equals total cost (tolerance 0.01). |
| FR-5.4 | p8: sum of per-model counts equals total request count in `usage_log`. |
| FR-5.5 | Single-key filtered totals MUST be <= unfiltered totals (p1, p3, p4). |

### FR-6: Structural Rules (All Panels)

| ID | Requirement |
|----|-------------|
| FR-6.1 | Every panel MUST have `title`, `type`, `datasource.uid`, `gridPos`, and >= 1 target; every target MUST have a `refId`. |
| FR-6.2 | ClickHouse targets MUST use `rawSql`; Prometheus targets MUST use `expr`. |
| FR-6.3 | ClickHouse targets MUST NOT contain `meta`, `editorType`, or `pluginVersion` keys (they trigger builder mode with an empty query). |
| FR-6.4 | Queries MUST NOT use `$__conditionalAll` macros. |
| FR-6.5 | All hex colors MUST come from the brand palette; leaderboard medal accents (white `#ffffff`, matte gold `#c9a44c`, silver `#a8a9ad`, bronze `#b07a3c`) are the only permitted additions. |

## 3. Non-Functional Requirements

| ID | Requirement |
|----|-------------|
| NFR-1.1 | Panels MUST render correctly from their own datasource in isolation, independent of known cross-table data-quality issues (see OPEN-ISSUES.md). |
| NFR-1.2 | All dashboards MUST load via Grafana provisioning without manual edits. |

## 4. Constraints

| ID | Constraint | Source |
|----|------------|--------|
| C-1 | ClickHouse database is `llm_gateway` (tables `request_log`, `usage_log`) | conf/migrations |
| C-2 | Dashboard JSONs are the tested artifact; tests verify against this requirements doc, not JSON structure alone | legacy dashboard spec |

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
| FR-1.1 3 dashboards / 16 panels | Implemented | conf/grafana/dashboards/*.json (3+11+2 panels) |
| FR-1.2 time range & refresh | Implemented | each dashboard: `now-7d`→`now`, `5s` |
| FR-2.x datasource split | Implemented | 11 CH + 5 Prom targets across dashboards |
| FR-3.x template variables | Implemented | `api_key` + `model` in all 3 dashboards |
| FR-4.x panel behaviors | Implemented | per-panel queries in dashboard JSONs |
| FR-5.x consistency invariants | Implemented (queries) | see OPEN-ISSUES.md for residual data-quality caveats |
| FR-6.x structural rules | Implemented | tests/config/dashboard_assert.sh |
