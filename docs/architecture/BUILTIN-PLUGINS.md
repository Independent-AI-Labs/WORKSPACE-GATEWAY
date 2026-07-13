# Built-in Plugins

Configuration truth: [`conf/apisix.yaml`](../../conf/apisix.yaml) and
[`conf/config.yaml`](../../conf/config.yaml). User guide:
[`BUILTIN-PLUGINS.md`](../BUILTIN-PLUGINS.md).

## request-id

Sets `X-Request-Id` on all three routes (`include_in_response: true`).
Correlates `usage_log` and `request_log` rows. Populated by APISIX
default log fields consumed by Vector.

## limit-count

Per-route RPM (see [`PLUGIN-PIPELINE.md`](PLUGIN-PIPELINE.md) matrix).

- **opencode / federated:** `key: http_x_key_hash` (from `key-meta`), 100/min
- **llamafile:** `key: remote_addr`, 600/min

Returns 429 when exceeded.

## http-logger

POST to `http://vector:8080/ingest` on log phase.

| Setting | Value |
|---------|-------|
| `include_req_body` | true |
| `include_resp_body` | true |
| `max_req_body_bytes` | 262144 |
| `max_resp_body_bytes` | 1048576 |
| `batch_max_size` | 1 |

Uses APISIX default log format (no custom `log_format`).

## prometheus

Exports at `0.0.0.0:9100` path `/apisix/prometheus/metrics`. Prometheus
scrapes every 15s per [`conf/prometheus.yml`](../../conf/prometheus.yml).

[`conf/config.yaml`](../../conf/config.yaml) adds per-key `key_hash` labels
from `$http_x_key_hash` on http_status, http_latency, bandwidth, and LLM
metric families.

## proxy-buffering

`disable: true` on all routes for SSE streaming.

## proxy-rewrite

| Route | Regex | Replacement |
|-------|-------|-------------|
| opencode | `^/opencode/(.*)$` | `/zen/go/$1` |
| federated | `^/opencode_federated/(.*)$` | `/zen/go/$1` |
| llamafile | `^/llamafile/(.*)$` | `/$1` |

## ai-rate-limiting

Listed in global `plugins` in `config.yaml` but **not** enabled on any route.