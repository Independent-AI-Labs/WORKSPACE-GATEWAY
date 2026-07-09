# OpenCode Integration

**Project:** WORKSPACE-GATEWAY
**Platform:** Apache APISIX 3.17.0, opencode v1.17.13+
**Upstream:** OpenCode Go (`https://opencode.ai/zen/go/v1`)
**Status:** Integration specification (revised)
**Date:** 2026-07-06

---

## 1. Architecture: APISIX as Relay to OpenCode Go

OpenCode Go is an AI gateway operated by the OpenCode team at
`https://opencode.ai/zen/go/v1`. It hosts a curated catalog of models
(MiniMax, Kimi, GLM, DeepSeek, Qwen, MiMo, HY3) behind a single set of
OpenAI-compatible endpoints. OpenCode Go handles all routing to
underlying providers -- the gateway never talks to `api.openai.com`,
`api.anthropic.com`, or any other provider directly.

```
opencode CLI (Bun/TypeScript)
  |
  |  AI SDK v5 serializes to OpenAI Chat Completions JSON
  |  fetch() sends to baseURL (APISIX)
  |  Authorization: Bearer vgw-gateway-key
  v
APISIX (port 9080)
  |  Plugins: key-resolver, key-meta, redact, sse-usage, limit-count,
  |           proxy-rewrite, http-logger, proxy-buffering, prometheus
  |  Two routes: /opencode/* -> opencode.ai:443 (passthrough)
  |              /opencode_federated/* -> opencode.ai:443 (virtual key)
  |  Both use proxy-rewrite to rewrite path to /zen/go/*
  |  Relays to OpenCode Go, passes SSE back unchanged
  v
OpenCode Go (https://opencode.ai/zen/go/v1)
  |  /v1/chat/completions  (OpenAI Chat Completions: MiniMax, Kimi,
  |                          GLM, DeepSeek, Qwen, MiMo, HY3)
  |  /v1/models            (model catalog)
  v
Underlying LLM Providers (MiniMax, Moonshot/Kimi, Zhipu/GLM, etc.)
```

**What APISIX touches:** HTTP headers (gateway key resolution via
key-resolver, proxy-rewrite rewrites path prefix), JSON body
(redact scans `messages[].content`),
SSE pass-through (buffering disabled), response logging (status,
latency, model, stream flag).

**What APISIX does NOT touch:** Request body format (Chat Completions,
whatever OpenCode Go expects), SSE event structure
(beyond text-field redaction), tool call schemas, reasoning/thinking
fields, provider-specific headers. OpenCode Go handles all
provider-specific wire format negotiation.

---

## 2. OpenCode Go: The Upstream

### 2.1 What Is OpenCode Go?

OpenCode Go is an AI gateway operated by the OpenCode team. It
benchmarks, verifies, and serves a curated list of models that work well
as coding agents. The gateway never needs to talk to individual
providers -- OpenCode Go handles that.

Source: `packages/web/src/content/docs/zen.mdx` in the opencode repo.

### 2.2 Endpoints

OpenCode Go exposes the OpenAI Chat Completions API under
`https://opencode.ai/zen/go/v1/`:

| Endpoint | Format | AI SDK Package | Models |
|----------|--------|----------------|--------|
| `/v1/chat/completions` | OpenAI Chat Completions | `@ai-sdk/openai-compatible` | minimax-m3, kimi-k2.6, glm-5, deepseek-v4-pro, mimo-v2.5, Qwen, HY3 |
| `/v1/models` | OpenAI Models list | any | Catalog endpoint |

The `/v1/models` endpoint returns the full model catalog:

```
GET https://opencode.ai/zen/go/v1/models
Authorization: Bearer <upstream-api-key>
```

### 2.3 Available Models on the Go Endpoint

The following models are available on the Go endpoint (not "free"
models -- these are the standard catalog):

| Display Name | Model ID | Endpoint |
|--------------|----------|----------|
| MiniMax M3 | `minimax-m3` | `/v1/chat/completions` |
| MiMo V2.5 | `mimo-v2.5` | `/v1/chat/completions` |
| GLM 5 | `glm-5` | `/v1/chat/completions` |
| DeepSeek V4 Pro | `deepseek-v4-pro` | `/v1/chat/completions` |
| Kimi K2.6 | `kimi-k2.6` | `/v1/chat/completions` |

All models on the Go endpoint use the OpenAI Chat Completions format.

### 2.4 OpenCode Go: The Primary Upstream

The Go endpoint at `https://opencode.ai/zen/go/v1/` is the PRIMARY
upstream. The main `/zen/v1/` endpoint returns `401 insufficient
balance` on our keys and is NOT used. The Go endpoint works and is the
current upstream. It serves Chinese model families (MiniMax, Kimi, GLM,
DeepSeek, Qwen, MiMo, HY3) via OpenAI Chat Completions format at
`/v1/chat/completions`.

### 2.5 Privacy Notes

- MiniMax: Provider-specific data policies apply.
- Kimi (Moonshot): Provider-specific data policies apply.
- GLM (Zhipu): Provider-specific data policies apply.
- DeepSeek: Provider-specific data policies apply.

---

## 3. opencode CLI Configuration

### 3.1 Two Providers: Virtual Key and Own Key

opencode is configured with two custom providers whose `baseURL` values
point at APISIX. The AI SDK package is `@ai-sdk/openai-compatible`
because all models on the Go endpoint use Chat Completions.

```jsonc
// opencode.json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "workspace-gw-private": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Workspace GW (Virtual Key)",
      "options": {
        "baseURL": "http://localhost:9080/opencode_federated/v1",
        "apiKey": "vgw-gateway-key",
        "headers": { "X-Tenant-ID": "default", "X-User-ID": "agent" }
      },
      "models": {
        "minimax-m3": { "name": "MiniMax M3", "limit": { "context": 160000, "output": 24000 } },
        "glm-5": { "name": "GLM 5", "limit": { "context": 160000, "output": 24000 } },
        "...": {}
      }
    },
    "workspace-gw-own": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Workspace GW (Own Key)",
      "options": {
        "baseURL": "http://localhost:9080/opencode/v1",
        "headers": { "X-Tenant-ID": "default", "X-User-ID": "agent" }
      },
      "models": { "...": "same models as workspace-gw-private" }
    }
  },
  "model": "workspace-gw-private/minimax-m3",
  "small_model": "workspace-gw-private/glm-5",
  "share": "disabled"
}
```

### 3.2 Variable Substitution

`baseURL` supports `${VAR}` substitution from environment variables:

```jsonc
{
  "options": {
    "baseURL": "http://${APISIX_HOST}:${APISIX_PORT}/opencode_federated/v1",
    "apiKey": "vgw-gateway-key"
  }
}
```

### 3.3 How opencode Sends Requests

When opencode uses `@ai-sdk/openai-compatible`, it sends standard OpenAI
Chat Completions to the `baseURL`:

```
POST /opencode_federated/v1/chat/completions
Authorization: Bearer vgw-gateway-key
Content-Type: application/json
X-Tenant-ID: default
X-User-ID: agent

{
  "model": "minimax-m3",
  "messages": [
    { "role": "system", "content": "..." },
    { "role": "user", "content": "..." }
  ],
  "stream": true,
  "tools": [...],
  "temperature": 0.7,
  "max_tokens": 4096
}
```

### 3.4 Auth Credential Storage

API keys can be set via `options.apiKey` in config, environment
variables, or `{file:path}` substitution. Credentials set via `/connect`
command are stored in `~/.local/share/opencode/auth.json`.

---

## 4. APISIX Route Configuration

### 4.1 Two Routes to OpenCode Go

Two APISIX routes cover the OpenCode Go endpoints. Both proxy to
`opencode.ai:443` with TLS and use `proxy-rewrite` to rewrite the path
prefix to `/zen/go/` before forwarding upstream.

- `/opencode/*` (passthrough): client supplies the real upstream key
  directly via `Authorization: Bearer <key>`. No key resolution.
- `/opencode_federated/*` (virtual key): client sends a `vgw-` prefixed
  virtual gateway key. The `key-resolver` plugin resolves it to the
  real upstream key (from OpenBao or env) and substitutes the
  `Authorization` header before forwarding.

```yaml
# conf/apisix.yaml -- APISIX standalone YAML mode

routes:
  # --- Federated route (virtual key via key-resolver) ---
  - id: relay-opencode-federated
    uri: /opencode_federated/*
    upstream:
      type: roundrobin
      scheme: https
      nodes:
        "opencode.ai:443": 1
    plugin_config_id: pc-relay-common
    plugins:
      key-resolver:
        token_prefix: "vgw-"
        kv_store: "openbao"
        kv_path: "secret/workspace-gateway/keys"
        upstream_key_env: "OPENCODE_API_KEY"
        fail_closed: true
      proxy-rewrite:
        regex_uri: ["^/opencode_federated/(.*)$", "/zen/go/$1"]
      sse-usage:
        extract_from: "stream"
      redact:
        patterns_file: "/etc/apisix/redact-patterns.json"

  # --- Passthrough route (own key, no resolution) ---
  - id: relay-opencode
    uri: /opencode/*
    upstream:
      type: roundrobin
      scheme: https
      nodes:
        "opencode.ai:443": 1
    plugins:
      proxy-rewrite:
        regex_uri: ["^/opencode/(.*)$", "/zen/go/$1"]
      sse-usage:
        extract_from: "stream"
      redact:
        patterns_file: "/etc/apisix/redact-patterns.json"

# --- Shared plugin config (applied to both routes) ---
plugin_configs:
  - id: pc-relay-common
    plugins:
      limit-count:
        count: 100
        time_window: 60
        rejected_code: 429
        key_type: var
        key: http_x_key_hash
        policy: local
      prometheus:
        prefer_name: true
      http-logger:
        uri: "http://vector:8080/ingest"
        method: POST
        content_type: "application/json"
        batch_max_size: 1
        include_req_body: true
        include_resp_body: true
        max_req_body_bytes: 8192
        max_resp_body_bytes: 8192
      proxy-buffering:
        disable: true
```

### 4.2 What Each Plugin Does on the Relay Path

| Plugin | Phase | What It Does |
|--------|-------|--------------|
| `key-resolver` (federated) | `access` | Resolves `vgw-` prefixed virtual gateway keys via OpenBao. If the token starts with `vgw-`, looks it up and substitutes the real upstream key. If the token does not start with `vgw-` (direct key on `/opencode/*` route), passes through as-is. |
| `proxy-rewrite` (both) | `access` | Rewrites the path prefix: `/opencode_federated/v1/...` or `/opencode/v1/...` becomes `/zen/go/v1/...` before forwarding upstream. |
| `sse-usage` (both) | `log` | Extracts token usage from SSE/JSON responses. Distinguishes streaming vs non-streaming and parses `usage` blocks so token counts are available for telemetry. |
| `key-meta` (both) | `access` | Computes truncated SHA-256 hash of the resolved key id (or raw Bearer token for passthrough) and sets `X-Key-Hash` header. Used by `limit-count` for per-key scoping and Prometheus for metric labels. |
| `limit-count` (both) | `access` | Per-key request rate limiting via fixed window. Scoped by `X-Key-Hash` on both routes; federated route uses variable `count`/`time_window` from `X-Gateway-Rate-Limit-*` headers. Returns `429` on exceed. |
| `proxy-buffering` (both) | `access` | Disables NGINX proxy buffering. Critical for SSE streaming. Without this, SSE chunks queue in NGINX buffer and streaming breaks. |
| `redact` (both) | `access` + `body_filter` | Scans request body JSON for PII before relay. Stores token map in `ctx`. Restores originals in response body (re-hydration). |
| `prometheus` (both) | `log` | Exports HTTP metrics: request count, latency histogram, status code distribution. Scraped at `/apisix/prometheus/metrics`. |
| `http-logger` (both) | `log` | Sends default APISIX JSON log (with request body, response body capped at 8192 bytes, client_ip, upstream_latency, route_id, start_time, consumer, and all request headers) to Vector at `http://vector:8080/ingest`. Vector inserts into ClickHouse for billing/analytics. |

### 4.3 API Key Flow

```
opencode config:
  options.apiKey = "vgw-gateway-key"  (virtual gateway key)

opencode sends:
  Authorization: Bearer vgw-gateway-key
  POST http://apisix:9080/opencode_federated/v1/chat/completions

APISIX key-resolver plugin:
  Checks if token starts with "vgw-".
  If yes: looks up in OpenBao, resolves to upstream OPENCODE_API_KEY
          (the real Go key).
  If no (direct key on /opencode/* route): passes through as-is.

APISIX proxy-rewrite plugin:
  Rewrites /opencode_federated/v1/chat/completions
       -> /zen/go/v1/chat/completions

APISIX upstream:
  Forwards to https://opencode.ai/zen/go/v1/chat/completions
  with the resolved upstream key (real Go key from OpenBao or env).

Result:
  - Client auth: APISIX key-resolver (vgw- virtual key)
  - Upstream auth: real Go key (from OpenBao or OPENCODE_API_KEY env)
```

### 4.4 SSE Streaming Path

When `stream: true` is in the request body:

1. opencode sends `POST /opencode_federated/v1/chat/completions` with `"stream": true`
2. APISIX `proxy-buffering` plugin disables NGINX buffering for this route
3. OpenCode Go responds with `Content-Type: text/event-stream`
4. APISIX passes SSE chunks through in real-time via `body_filter`
5. `redact` plugin scans SSE chunks for PII in `delta.content` fields
6. `sse-usage` plugin extracts token usage from the SSE tail frame
7. `http-logger` captures the final response metadata
8. opencode's AI SDK parses the SSE stream

---

## 5. Telemetry and Observability

### 5.1 Metrics (Prometheus)

The `prometheus` plugin exports metrics per route. Scrape endpoint:
`http://apisix:9100/apisix/prometheus/metrics`.

### 5.2 Telemetry Logging (http-logger to Vector to ClickHouse)

The `http-logger` plugin sends a JSON log entry to Vector for every
request/response. The http-logger now uses the default APISIX log
format (no custom `log_format`). The log includes `request.body`,
`response.body`, `client_ip`, `upstream_latency`, `route_id`,
`start_time`, `consumer`, and all request headers. Vector parses and
inserts into ClickHouse.

Log entry format (sent to Vector, default APISIX format):
```json
{
  "request": {
    "uri": "/opencode_federated/v1/chat/completions",
    "method": "POST",
    "body": "{\"model\":\"minimax-m3\",\"stream\":true,...}",
    "headers": {
      "authorization": "Bearer vgw-gateway-key",
      "x-tenant-id": "default",
      "x-user-id": "agent"
    }
  },
  "response": {
    "status": 200,
    "body": "{\"id\":\"chatcmpl-...\",\"usage\":{...}}"
  },
  "client_ip": "10.0.0.42",
  "upstream_latency": 1234,
  "route_id": "relay-opencode-federated",
  "start_time": 1751808000,
  "consumer": {}
}
```

Vector pipeline (`conf/vector.toml`) parses the JSON, extracts `model`
and `stream` from the request body via `parse_json`, and reads headers
with `get!`:
```toml
[sources.apisix_http_logger]
type = "http_server"
address = "0.0.0.0:8080"
path = "/ingest"
encoding = "json"

[transforms.parse_log]
type = "remap"
inputs = ["apisix_http_logger"]
source = """
. = parse_json!(.message)
.timestamp = now()
.req_body = parse_json!(get!(., ["request", "body"]))
.model = get!(.req_body, ["model"])
.stream = get!(.req_body, ["stream"], false)
.provider = "opencode"
.route_id = get!(., ["route_id"])
.status = get!(.["response"], ["status"])
.client_ip = get!(., ["client_ip"])
.upstream_latency = get!(., ["upstream_latency"])
.tenant_id = get!(.["request", "headers"], ["x-tenant-id"])
.user_id = get!(.["request", "headers"], ["x-user-id"])
"""

[sinks.clickhouse_request_log]
type = "clickhouse"
inputs = ["parse_log"]
endpoint = "http://clickhouse:8123"
database = "llm_gateway"
table = "request_log"
skip_unknown_fields = true
```

### 5.3 Grafana: Gateway Dashboards

The gateway observability stack provides 3 separate Grafana dashboards:

- **Gateway Cost & Usage**: `http://localhost:3030/d/gateway-cost-usage/gateway-cost-usage`
  - token usage by category (p3), model distribution (p8), cost over time (p15).
  All ClickHouse datasource.
- **Gateway Operations & Health**: `http://localhost:3030/d/gateway-ops-health/gateway-ops-health`
  - total requests, active connections, error rate, request rate, status code
  breakdown, latency percentiles, avg latency by model, bandwidth, shared dict
  memory, stream abort rate, stream status. Mixed Prometheus + ClickHouse.
- **Gateway Cost Leaderboard**: `http://localhost:3030/d/gateway-cost-leaderboard/gateway-cost-leaderboard`
  - top clients ranked by cost and token consumption (p20, ClickHouse table).

All 3 dashboards share identical `templating` (api_key + model variables) and
the same time range / refresh settings.

### 5.4 Rate Limiting (limit-count + Tier 3 budget)

Request RPM is enforced by APISIX built-in `limit-count` plugin (fixed
window). It is scoped by `X-Key-Hash` (set by `key-meta`) so every unique
client key gets its own counter. The federated route uses variable
`count`/`time_window` read from OpenBao by `key-resolver` and injected as
`X-Gateway-Rate-Limit-RPM` / `X-Gateway-Rate-Limit-Window` headers.

Per-key token/cost budgets are enforced in custom Lua: `key-resolver`
reads budget fields from the OpenBao key record and checks a shared dict
counter at access phase; `sse-usage` increments the counter at log phase.
`ai-rate-limiting` is NOT used (it requires `ai-proxy`/`ai-proxy-multi`
to populate token usage context, which our route chain lacks).

### 5.5 PII Redaction (redact plugin)

Custom Lua plugin. Runs in `access` phase (request body) and
`body_filter` phase (response body, including SSE chunks).

See `PLUGIN-REDACT-LUA.md` for full plugin spec.

---

## 6. Integration Summary

### What We Build

1. **APISIX routes**: two routes `/opencode/*` (passthrough) and
   `/opencode_federated/*` (virtual key) to `opencode.ai:443` with the
   full plugin stack (key-resolver on federated only, proxy-rewrite on
    both, key-meta, sse-usage, limit-count, prometheus, http-logger,
   proxy-buffering, redact).
2. **opencode config**: two custom providers --
   `workspace-gw-private` (virtual key, baseURL
   `http://localhost:9080/opencode_federated/v1`) and
   `workspace-gw-own` (own key, baseURL
   `http://localhost:9080/opencode/v1`). `npm` is
   `@ai-sdk/openai-compatible`.
3. **Telemetry pipeline**: APISIX `http-logger` to Vector to ClickHouse.
   Prometheus scrapes APISIX metrics endpoint at `apisix:9100`. Grafana
   dashboards at `localhost:3030` (Cost & Usage, Operations & Health,
   Cost Leaderboard).
4. **PII redaction**: custom Lua `redact` plugin on both OpenCode Go
   routes.
5. **Rate limiting**: `limit-count` plugin, per-key RPM (federated route: variable limits from OpenBao). Tier 3 token/cost budget in custom Lua via shared dict.
6. **SSE pass-through**: `proxy-buffering` plugin with `disable: true`.
7. **Path rewriting**: `proxy-rewrite` rewrites both route prefixes to
   `/zen/go/` before forwarding upstream.

### What We Do NOT Build

- No format conversion in APISIX (OpenCode Go handles all
  provider-specific wire format negotiation).
- No direct connections to individual LLM providers (OpenAI, Anthropic,
  Google, etc.). OpenCode Go is the only upstream.
- No OAuth flows in APISIX (opencode handles OAuth natively).
- No tool execution in APISIX (opencode's agent loop handles it).
- No session management in APISIX (opencode's server handles it).

### Data Flow

```
 1. User sends prompt to opencode CLI
 2. opencode creates session, runs agent prompt loop
 3. Agent loop calls AI SDK streamText()
 4. AI SDK serializes ModelMessage[] to OpenAI Chat Completions JSON
 5. AI SDK fetch() sends HTTP to APISIX (baseURL in opencode config)
 6. APISIX key-resolver resolves vgw- key via OpenBao (federated route)
    or passes the direct key through (passthrough route)
 7. APISIX proxy-rewrite rewrites path (/opencode_federated/... or
    /opencode/...) to /zen/go/...
 8. APISIX limit-count checks per-key request count (federated: variable window from OpenBao headers)
 9. APISIX redact scans request body for PII
10. APISIX relays to OpenCode Go (https://opencode.ai/zen/go/v1/...)
11. OpenCode Go routes to the underlying LLM provider
12. Provider responds (JSON or SSE stream)
13. APISIX proxy-buffering passes SSE through unbuffered
14. APISIX sse-usage extracts token usage from the SSE tail
15. APISIX redact scans response for PII (re-hydrate tokens)
16. APISIX prometheus records metrics
17. APISIX http-logger sends log to Vector -> ClickHouse
18. opencode AI SDK parses response/SSE
19. opencode SessionProcessor builds message parts
20. Client receives response
```

---

## 7. opencode Server API Reference

The `opencode serve` command runs an HTTP server (default `:4096`) with
an OpenAPI 3.1 spec at `GET /doc`. All endpoints below are from the
v1.17.13 server docs. This is the opencode CLI's own server API, NOT
the OpenCode Go upstream API.

### 7.1 Authentication

HTTP Basic Auth. Enabled when `OPENCODE_SERVER_PASSWORD` is set.

| Header | Format |
|--------|--------|
| `Authorization` | `Basic base64(username:password)` |
| Query `?auth_token=` | `base64(username:password)` |

Username defaults to `opencode`. Override with
`OPENCODE_SERVER_USERNAME`. No auth when password is unset (default).

### 7.2 Global

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/global/health` | Server health and version |
| `GET` | `/global/event` | Global events (SSE stream) |

### 7.3 Project

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/project` | List all projects |
| `GET` | `/project/current` | Get the current project |

### 7.4 Path and VCS

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/path` | Get the current path |
| `GET` | `/vcs` | Get VCS info for current project |

### 7.5 Instance

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/instance/dispose` | Dispose the current instance |

### 7.6 Config

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/config` | Get config info |
| `PATCH` | `/config` | Update config |
| `GET` | `/config/providers` | List providers and default models |

### 7.7 Provider

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/provider` | List all providers |
| `GET` | `/provider/auth` | Get provider auth methods |
| `POST` | `/provider/{id}/oauth/authorize` | Authorize provider via OAuth |
| `POST` | `/provider/{id}/oauth/callback` | Handle OAuth callback |

### 7.8 Sessions

| Method | Path | Description | Body / Query |
|--------|------|-------------|--------------|
| `GET` | `/session` | List all sessions | |
| `POST` | `/session` | Create a new session | `{ parentID?, title? }` |
| `GET` | `/session/status` | Get status for all sessions | |
| `GET` | `/session/:id` | Get session details | |
| `DELETE` | `/session/:id` | Delete session and all data | |
| `PATCH` | `/session/:id` | Update session properties | `{ title? }` |
| `GET` | `/session/:id/children` | Get child sessions | |
| `GET` | `/session/:id/todo` | Get todo list for session | |
| `POST` | `/session/:id/init` | Analyze app, create AGENTS.md | `{ messageID, providerID, modelID }` |
| `POST` | `/session/:id/fork` | Fork session at a message | `{ messageID? }` |
| `POST` | `/session/:id/abort` | Abort a running session | |
| `POST` | `/session/:id/share` | Share a session | |
| `DELETE` | `/session/:id/share` | Unshare a session | |
| `GET` | `/session/:id/diff` | Get diff for this session | `?messageID=` |
| `POST` | `/session/:id/summarize` | Summarize the session | `{ providerID, modelID }` |
| `POST` | `/session/:id/revert` | Revert a message | `{ messageID, partID? }` |
| `POST` | `/session/:id/unrevert` | Restore all reverted messages | |
| `POST` | `/session/:id/permissions/:permissionID` | Respond to permission request | `{ response, remember? }` |

### 7.9 Messages (the core prompt endpoint)

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/session/:id/message` | List messages in session |
| `POST` | `/session/:id/message` | Send a message, wait for response |
| `GET` | `/session/:id/message/:messageID` | Get message details |
| `POST` | `/session/:id/prompt_async` | Send a message asynchronously |
| `POST` | `/session/:id/command` | Execute a slash command |
| `POST` | `/session/:id/shell` | Run a shell command |

#### POST /session/:id/message Request Body

```json
{
  "messageID": "string (optional, for replies)",
  "model": {
    "providerID": "string (e.g. \"workspace-gw-private\")",
    "modelID": "string (e.g. \"minimax-m3\")"
  },
  "agent": "string (optional, e.g. \"build\" or \"plan\")",
  "noReply": false,
  "system": "string (optional, override system prompt)",
  "tools": ["string (optional, restrict tool list)"],
  "parts": [
    { "type": "text", "text": "user message text" },
    { "type": "image", "source": { "type": "base64", "mediaType": "image/png", "data": "..." } },
    { "type": "file", "path": "/path/to/file" }
  ],
  "format": {
    "type": "json_schema",
    "schema": { "type": "object", "properties": { ... } },
    "retryCount": 2
  }
}
```

#### POST /session/:id/message Response

```json
{
  "info": {
    "id": "msg_abc123",
    "sessionID": "sess_xyz789",
    "role": "assistant",
    "time": 1720195200,
    "model": {
      "providerID": "workspace-gw-private",
      "modelID": "minimax-m3"
    },
    "cost": {
      "input": 0.003,
      "output": 0.015,
      "total": 0.018
    },
    "tokens": {
      "input": 1500,
      "output": 800,
      "reasoning": 0,
      "cache": { "read": 0, "write": 0 }
    },
    "error": null
  },
  "parts": [
    { "type": "text", "text": "assistant response text" },
    { "type": "reasoning", "text": "thinking content" },
    {
      "type": "tool",
      "id": "tool_call_1",
      "tool": "read",
      "state": { "status": "completed" },
      "input": { "filePath": "/src/main.ts" },
      "output": { "content": "file contents..." }
    }
  ]
}
```

### 7.10 Commands

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/command` | List all commands |

### 7.11 Files

| Method | Path | Description | Query |
|--------|------|-------------|-------|
| `GET` | `/find` | Search for text in files | `?pattern=` |
| `GET` | `/find/file` | Find files/dirs by name | `?query=&type=&directory=&limit=` |
| `GET` | `/find/symbol` | Find workspace symbols | `?query=` |
| `GET` | `/file` | List files and directories | `?path=` |
| `GET` | `/file/content` | Read a file | `?path=` |
| `GET` | `/file/status` | Get status for tracked files | |

### 7.12 Tools (Experimental)

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/experimental/tool/ids` | List all tool IDs |
| `GET` | `/experimental/tool` | List tools with JSON schemas |

### 7.13 LSP, Formatters and MCP

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/lsp` | Get LSP server status |
| `GET` | `/formatter` | Get formatter status |
| `GET` | `/mcp` | Get MCP server status |
| `POST` | `/mcp` | Add MCP server dynamically |

### 7.14 Agents

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/agent` | List all available agents |

### 7.15 Logging

| Method | Path | Description | Body |
|--------|------|-------------|------|
| `POST` | `/log` | Write log entry | `{ service, level, message, extra? }` |

### 7.16 TUI Control

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/tui/append-prompt` | Append text to the prompt |
| `POST` | `/tui/open-help` | Open the help dialog |
| `POST` | `/tui/open-sessions` | Open the session selector |
| `POST` | `/tui/open-themes` | Open the theme selector |
| `POST` | `/tui/open-models` | Open the model selector |
| `POST` | `/tui/submit-prompt` | Submit the current prompt |
| `POST` | `/tui/clear-prompt` | Clear the prompt |
| `POST` | `/tui/execute-command` | Execute a command |
| `POST` | `/tui/show-toast` | Show toast |
| `GET` | `/tui/control/next` | Wait for next control request |
| `POST` | `/tui/control/response` | Respond to a control request |

### 7.17 Auth

| Method | Path | Description | Body |
|--------|------|-------------|------|
| `PUT` | `/auth/:id` | Set auth credentials for a provider | Provider-specific |

### 7.18 Events (SSE)

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/event` | Server-sent events stream |

First event is `server.connected`, then bus events. 10-second heartbeat
(`server.heartbeat`). Response headers: `Cache-Control: no-cache,
no-transform`, `X-Accel-Buffering: no`, `Content-Type: text/event-stream`.

Events include: `session.updated`, `session.created`, `session.deleted`,
`session.idle`, `session.error`, `message.updated`, `message.removed`,
`message.part.updated`, `message.part.removed`, `tool.execute.before`,
`tool.execute.after`, `permission.asked`, `permission.replied`,
`file.edited`, `lsp.updated`, `server.connected`, `server.heartbeat`,
`server.instance.disposed`.

### 7.19 Docs

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/doc` | OpenAPI 3.1 specification |

---

## 8. opencode Provider and Model Selection

### 8.1 How Providers Work

opencode uses the Vercel AI SDK v5 (`ai` package). Each provider is an
AI SDK factory that returns a `LanguageModelV3` interface. The factory
handles HTTP communication with the upstream LLM API.

Three-tier provider loading:
1. **Bundled** (in opencode binary): `@ai-sdk/openai`,
   `@ai-sdk/anthropic`, `@ai-sdk/google`, `@ai-sdk/azure`,
   `@ai-sdk/amazon-bedrock`, `@ai-sdk/openai-compatible`,
   `@openrouter/ai-sdk-provider`, and 15+ more.
2. **Custom loaders** (per-provider quirks): Anthropic beta headers,
   Bedrock SigV4, Vertex ADC, Azure URL construction, Copilot device
   flow, etc.
3. **Dynamic NPM import**: for any provider not bundled, opencode
   installs the npm package at runtime and imports it.

### 8.2 Model ID Format

Models are identified as `providerID/modelID`. Examples:
- `workspace-gw-private/minimax-m3` (virtual-key custom provider via APISIX to OpenCode Go)
- `anthropic/claude-sonnet-4-5` (direct Anthropic)
- `workspace-gw-own/glm-5` (own-key custom provider via APISIX to OpenCode Go)

### 8.3 Model Resolution Priority

1. `--model` CLI flag (e.g., `-m workspace-gw-private/minimax-m3`)
2. `model` key in `opencode.json` config
3. Last used model (persisted)
4. First model by internal priority

### 8.4 Custom Provider Configuration

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "workspace-gw-private": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Workspace GW (Virtual Key)",
      "options": {
        "baseURL": "http://localhost:9080/opencode_federated/v1",
        "apiKey": "vgw-gateway-key",
        "headers": { "X-Tenant-ID": "default", "X-User-ID": "agent" }
      },
      "models": {
        "minimax-m3": {
          "name": "MiniMax M3",
          "limit": { "context": 160000, "output": 24000 },
          "cost": { "input": 0, "output": 0 },
          "options": { "temperature": 0.7 }
        }
      }
    },
    "workspace-gw-own": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Workspace GW (Own Key)",
      "options": {
        "baseURL": "http://localhost:9080/opencode/v1",
        "headers": { "X-Tenant-ID": "default", "X-User-ID": "agent" }
      },
      "models": {
        "glm-5": {
          "name": "GLM 5",
          "limit": { "context": 160000, "output": 24000 }
        }
      }
    }
  },
  "model": "workspace-gw-private/minimax-m3"
}
```

The `npm` field selects which AI SDK factory builds the HTTP client.
`@ai-sdk/openai-compatible` speaks OpenAI Chat Completions format. The
`baseURL` is where opencode sends HTTP requests. `apiKey` is injected as
`Authorization: Bearer <key>` by the AI SDK.

### 8.5 Provider baseURL Override

Every provider accepts `options.baseURL`. This is the primary mechanism
for routing through APISIX. Set `baseURL` to the APISIX route and
opencode will send all requests for that provider to APISIX instead of
the provider's real endpoint.

---

## 9. OpenAI Compatibility Assessment

### 9.1 opencode Server API vs OpenAI API

| Aspect | OpenAI API | opencode Server API |
|--------|-----------|---------------------|
| Chat endpoint | `POST /v1/chat/completions` | `POST /session/:id/message` |
| Models endpoint | `GET /v1/models` | `GET /provider`, `GET /config/providers` |
| Request format | `{ model, messages, stream, tools, ... }` | `{ parts: [{ type, text }], model?: { providerID, modelID } }` |
| Response format | `{ choices: [{ message: { content } }] }` | `{ info: Message, parts: Part[] }` |
| SSE format | Per-request `data: { delta }` | Global `/event` bus (10s heartbeat) |
| Auth | `Authorization: Bearer sk-...` | HTTP Basic (`OPENCODE_SERVER_PASSWORD`) |
| Sessions | Stateless | Stateful (create, list, fork, revert, share) |
| Tools | Client-side declaration | Server-side execution with permissions |
| Token usage | `usage: { prompt_tokens, completion_tokens }` | `info.tokens: { input, output, reasoning }` |
| Cost | Not returned | `info.cost: { input, output, total }` |

### 9.2 opencode's AI SDK Wire Format (what APISIX sees)

When opencode uses `@ai-sdk/openai-compatible`, it sends standard OpenAI
Chat Completions to the `baseURL`:

```
POST /opencode_federated/v1/chat/completions
Authorization: Bearer vgw-gateway-key
Content-Type: application/json

{
  "model": "minimax-m3",
  "messages": [
    { "role": "system", "content": "..." },
    { "role": "user", "content": "..." }
  ],
  "stream": true,
  "tools": [...],
  "temperature": 0.7,
  "max_tokens": 4096
}
```

APISIX sees this format. It does not parse or convert it. The
`key-resolver` plugin resolves the `vgw-` bearer token to the real
upstream key, the `proxy-rewrite` plugin rewrites the path prefix, and
then APISIX relays the HTTP request to OpenCode Go. The only body
parsing APISIX does is:
- `limit-count`: scoped by `X-Key-Hash` header; federated route reads dynamic limits from `X-Gateway-Rate-Limit-*` headers
- `redact`: reads `messages[].content` text fields
- `http-logger`: reads `model` and `stream` fields for log metadata

### 9.3 OpenCode Go Provider Compatibility Matrix

All models on OpenCode Go are accessible through the gateway. Every
model family uses the OpenAI Chat Completions format at
`/v1/chat/completions`:

| Model Family | Native Format | Go Endpoint | AI SDK Package |
|--------------|--------------|--------------|----------------|
| MiniMax | OpenAI Chat Completions | `/v1/chat/completions` | `@ai-sdk/openai-compatible` |
| Kimi | OpenAI Chat Completions | `/v1/chat/completions` | `@ai-sdk/openai-compatible` |
| GLM | OpenAI Chat Completions | `/v1/chat/completions` | `@ai-sdk/openai-compatible` |
| DeepSeek | OpenAI Chat Completions | `/v1/chat/completions` | `@ai-sdk/openai-compatible` |
| Qwen | OpenAI Chat Completions | `/v1/chat/completions` | `@ai-sdk/openai-compatible` |
| MiMo | OpenAI Chat Completions | `/v1/chat/completions` | `@ai-sdk/openai-compatible` |
| HY3 | OpenAI Chat Completions | `/v1/chat/completions` | `@ai-sdk/openai-compatible` |

For the gateway, all models use `/v1/chat/completions` and
`@ai-sdk/openai-compatible`. The two APISIX routes
(`/opencode/*` and `/opencode_federated/*`) cover them all.

---

## 10. opencode Extensions Beyond OpenAI API

### 10.1 Session Management

opencode is stateful. Sessions persist message history, tool outputs,
file diffs, and todo lists. OpenAI API is stateless.

### 10.2 Agent System

opencode has built-in agents (build, plan) and custom agents. Each
agent has its own system prompt, tool set, and permissions.

### 10.3 Tool Execution

opencode executes tools server-side. The LLM calls tools, opencode
executes them, and returns results to the LLM. OpenAI expects the
client to execute tools.

### 10.4 SSE Event Bus

opencode has a global event bus (`GET /event`) that streams all session
events. OpenAI has per-request SSE only.

### 10.5 Message Part Types

opencode messages have rich part types: text, image, reasoning, tool,
file, agent, subtask, tool-approval-request, tool-approval-response.

### 10.6 Structured Output

Both support JSON schema output, but the API differs: OpenAI uses
`response_format`, opencode uses `format` with `retryCount`.

### 10.7 Context Management

opencode has auto-compaction when context overflows, configurable
pruning, and token budget management.

### 10.8 Permission System

opencode has `allow` / `ask` / `deny` per tool, per agent, with
interactive prompts and wildcard matching.

### 10.9 Plugin System

opencode has 20+ hook events, npm package or local file loading,
and custom tools with Zod schemas.

### 10.10 LSP and Formatter Integration

opencode has auto-discovered LSP servers, code formatters, symbol
search, and diagnostics.
