# Open Issues and Changelog

Items still open between documentation and desired behavior. Fixed items
are summarized in the changelog only (not repeated in child docs).

## Open

### Cross-table token comparison

**[OPEN]** `request_log.prompt_tokens` / `completion_tokens` (Vector
`parse_json` on response body) often read **0 for SSE** because the body
is a multi-line stream. `usage_log` counts from `sse-usage` are accurate.
Comparing the two columns is apples to oranges.

### Reconciler and billing enrichment

**[OPEN]** `res/scripts/reconciler.sh` logs gateway-side totals only.
Upstream provider API comparison and `billing_discrepancies` writes are
v2 scope. `billing_ledger.rate_input` / `rate_output` default to 0 until
a models.dev pricing snapshot lands in ClickHouse.

### Federated rate limits vs OpenBao headers

**[OPEN]** `key-resolver` can set `X-Gateway-Rate-Limit-*` headers, but
`conf/apisix.yaml` uses **static** `limit-count` (100 RPM per
`http_x_key_hash`) on opencode and federated routes. Per-key variable
limits from OpenBao are not wired in config today.

### CJK token estimation accuracy

**[OPEN]** `sse_usage_lib.count_tokens` uses a byte-range heuristic
(~10-20% error for CJK vs provider counts). See
[`COST-CALC-LUA.md`](../COST-CALC-LUA.md).

## Fixed changelog (summary)

| Date | Fix |
|------|-----|
| 2026-07 | etcd traditional mode; Admin API + `${{ADMIN_KEY}}` |
| 2026-07 | `request_id` in usage_log and request_log; `request-id` plugin |
| 2026-07 | `event_id` integer-seconds; model canonicalization both paths |
| 2026-07 | http-logger 256K / 1MiB body limits |
| 2026-07 | `billing_ledger_mv` on usage_log INSERT |
| 2026-07 | golang-migrate `conf/migrations/` (v4.19.1) |
| 2026-07 | relay-llamafile route; 3-provider sync-models |
| 2026-07 | Grafana join on `request_id`; dashboards p20/p21 |