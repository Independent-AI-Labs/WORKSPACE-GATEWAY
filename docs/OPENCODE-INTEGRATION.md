# OpenCode Integration

**Project:** WORKSPACE-GATEWAY
**Platform:** Apache APISIX 3.17.0, opencode v1.17.13+
**Upstream:** OpenCode Zen (`https://opencode.ai/zen/v1`)
**Status:** Integration specification (revised)
**Date:** 2026-07-06

---

## 1. Architecture: APISIX as Relay to OpenCode Zen

OpenCode Zen is an AI gateway operated by the OpenCode team at
`https://opencode.ai/zen/v1`. It hosts a curated catalog of models
(GPT, Claude, Gemini, DeepSeek, MiniMax, GLM, Kimi, Qwen, and free
stealth/trial models) behind a single set of OpenAI-compatible and
provider-native endpoints. Zen handles all routing to underlying
providers -- the gateway never talks to `api.openai.com`,
`api.anthropic.com`, or any other provider directly.

```
opencode CLI (Bun/TypeScript)
  |
  |  AI SDK v5 serializes to OpenAI Chat Completions JSON
  |  fetch() sends to baseURL (APISIX)
  |  Authorization: Bearer <zen-api-key>
  v
APISIX (port 9080)
  |  Plugins: key-auth, ai-rate-limiting, prometheus, http-logger,
  |           proxy-buffering(off), redact
  |  Single route: /zen/* -> opencode.ai:443
  |  Relays to Zen, passes SSE back unchanged
  v
OpenCode Zen (https://opencode.ai/zen/v1)
  |  /v1/chat/completions  (OpenAI-compatible: DeepSeek, MiniMax,
  |                          GLM, Kimi, Grok, free models)
  |  /v1/responses         (OpenAI Responses: GPT 5.x)
  |  /v1/messages          (Anthropic Messages: Claude, Qwen)
  |  /v1/models/gemini-*   (Google native: Gemini)
  |  /v1/models            (model catalog)
  v
Underlying LLM Providers (OpenAI, Anthropic, Google, etc.)
```

**What APISIX touches:** HTTP headers (gateway key validation via
key-auth), JSON body (rate-limiting reads `model` field, redact scans
`messages[].content`), SSE pass-through (buffering disabled), response
logging (status, latency, model, stream flag).

**What APISIX does NOT touch:** Request body format (Chat Completions,
Anthropic Messages, Gemini, whatever Zen expects), SSE event structure
(beyond text-field redaction), tool call schemas, reasoning/thinking
fields, provider-specific headers. Zen handles all provider-specific
wire format negotiation.

---

## 2. OpenCode Zen: The Upstream

### 2.1 What Is Zen?

Zen is an AI gateway operated by the OpenCode team. It benchmarks,
verifies, and serves a curated list of models that work well as coding
agents. The gateway never needs to talk to individual providers -- Zen
handles that.

Source: `packages/web/src/content/docs/zen.mdx` in the opencode repo.

### 2.2 Endpoints

Zen exposes multiple API formats under `https://opencode.ai/zen/v1/`:

| Endpoint | Format | AI SDK Package | Models |
|----------|--------|----------------|--------|
| `/v1/chat/completions` | OpenAI Chat Completions | `@ai-sdk/openai-compatible` | DeepSeek, MiniMax, GLM, Kimi, Grok, Big Pickle, all free models |
| `/v1/responses` | OpenAI Responses API | `@ai-sdk/openai` | GPT 5.x, GPT 5.x Codex |
| `/v1/messages` | Anthropic Messages API | `@ai-sdk/anthropic` | Claude, Qwen |
| `/v1/models/{id}` | Google native | `@ai-sdk/google` | Gemini |
| `/v1/models` | OpenAI Models list | any | Catalog endpoint |

The `/v1/models` endpoint returns the full model catalog:

```
GET https://opencode.ai/zen/v1/models
Authorization: Bearer <zen-api-key>
```

### 2.3 Free Models

The following models are free for a limited time:

| Display Name | Model ID | Endpoint |
|--------------|----------|----------|
| Big Pickle | `big-pickle` | `/v1/chat/completions` |
| MiMo-V2.5 Free | `mimo-v2.5-free` | `/v1/chat/completions` |
| North Mini Code Free | `north-mini-code-free` | `/v1/chat/completions` |
| Nemotron 3 Ultra Free | `nemotron-3-ultra-free` | `/v1/chat/completions` |
| DeepSeek V4 Flash Free | `deepseek-v4-flash-free` | `/v1/chat/completions` |

All free models use the OpenAI Chat Completions format.

### 2.4 Zen "Go" Sub-endpoint

Zen also exposes a "Go" sub-endpoint at `https://opencode.ai/zen/go/v1/`
with a different model catalog (Chinese model families: MiniMax, Kimi,
GLM, DeepSeek, Qwen, MiMo, HY3). This is a separate tier from the main
Zen catalog. The main `/zen/v1/` endpoint is the primary upstream.

### 2.5 Privacy Notes

- Big Pickle: Data may be used to improve the model during free period.
- North Mini Code Free: Data may be retained and used. Do not submit
  personal or confidential data.
- Nemotron 3 Ultra Free: NVIDIA trial terms apply. Usage logged.
- OpenAI APIs: 30-day retention per OpenAI data policies.
- Anthropic APIs: 30-day retention per Anthropic data policies.

---

## 3. opencode CLI Configuration

### 3.1 Single Provider: Gateway to Zen

opencode is configured with a single custom provider whose `baseURL`
points at APISIX. APISIX relays to Zen. The AI SDK package is
`@ai-sdk/openai-compatible` because all free models use Chat Completions.

```jsonc
// opencode.json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "gateway": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Gateway (via APISIX to Zen)",
      "options": {
        "baseURL": "http://apisix:9080/zen/v1",
        "apiKey": "{env:OPENCODE_ZEN_API_KEY}"
      },
      "models": {
        "big-pickle": {
          "name": "Big Pickle",
          "limit": { "context": 128000, "output": 65536 }
        },
        "mimo-v2.5-free": {
          "name": "MiMo V2.5 Free",
          "limit": { "context": 128000, "output": 65536 }
        },
        "north-mini-code-free": {
          "name": "North Mini Code Free",
          "limit": { "context": 128000, "output": 65536 }
        },
        "nemotron-3-ultra-free": {
          "name": "Nemotron 3 Ultra Free",
          "limit": { "context": 128000, "output": 65536 }
        },
        "deepseek-v4-flash-free": {
          "name": "DeepSeek V4 Flash Free",
          "limit": { "context": 128000, "output": 65536 }
        }
      }
    }
  },
  "model": "gateway/big-pickle",
  "small_model": "gateway/mimo-v2.5-free",
  "share": "disabled"
}
```

### 3.2 Variable Substitution

`baseURL` supports `${VAR}` substitution from environment variables:

```jsonc
{
  "options": {
    "baseURL": "http://${APISIX_HOST}:${APISIX_PORT}/zen/v1",
    "apiKey": "{env:OPENCODE_ZEN_API_KEY}"
  }
}
```

### 3.3 How opencode Sends Requests

When opencode uses `@ai-sdk/openai-compatible`, it sends standard OpenAI
Chat Completions to the `baseURL`:

```
POST /zen/v1/chat/completions
Authorization: Bearer <zen-api-key>
Content-Type: application/json

{
  "model": "big-pickle",
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

### 4.1 Single Route to Zen

One APISIX route covers all Zen endpoints. The route matches `/zen/*`
and proxies to `opencode.ai:443` with TLS. No path rewriting is needed
-- the `/zen/` prefix is part of Zen's URL structure.

```yaml
# conf/apisix.yaml -- APISIX standalone YAML mode

routes:
  - id: relay-zen
    uri: /zen/*
    upstream:
      type: roundrobin
      scheme: https
      nodes:
        "opencode.ai:443": 1
    plugins:
      key-auth: {}
      ai-rate-limiting:
        model: "$request_body.model"
        limit: 1000
        time_window: 60
        rejected_code: 429
      prometheus:
        prefer_name: true
      http-logger:
        uri: "http://vector:8080/ingest"
        method: POST
        content_type: "application/json"
        batch_max_size: 1
        include_req_body: false
        include_resp_body: false
        log_format:
          provider: "opencode-zen"
          model: "$request_body.model"
          stream: "$request_body.stream"
          method: "$request_method"
          uri: "$uri"
          status: "$status"
          latency: "$upstream_latency_ms"
      proxy-buffering:
        disable: true
      redact:
        patterns_file: "/etc/apisix/redact-patterns.json"

consumers:
  - id: opencode
    key_auth_credentials:
      - key: "opencode-gateway-key"
```

### 4.2 What Each Plugin Does on the Relay Path

| Plugin | Phase | What It Does |
|--------|-------|--------------|
| `key-auth` | `access` | Validates the gateway consumer key (`opencode-gateway-key`). This is the gateway auth key, NOT the Zen API key. Two different keys. |
| `ai-rate-limiting` | `access` | Reads `model` from request body. Enforces per-model RPM. Returns `429` on exceed. |
| `proxy-buffering` | `access` | Disables NGINX proxy buffering. Critical for SSE streaming. Without this, SSE chunks queue in NGINX buffer and streaming breaks. |
| `redact` | `access` + `body_filter` | Scans request body JSON for PII before relay. Stores token map in `ctx`. Restores originals in response body (re-hydration). |
| `prometheus` | `log` | Exports HTTP metrics: request count, latency histogram, status code distribution. Scraped at `/apisix/prometheus/metrics`. |
| `http-logger` | `log` | Sends structured JSON log to Vector at `http://vector:8080/ingest`. Vector inserts into ClickHouse for billing/analytics. |

### 4.3 API Key Flow

```
opencode config:
  options.apiKey = "{env:OPENCODE_ZEN_API_KEY}"  (real Zen key)

opencode sends:
  Authorization: Bearer sk-C0kL...   (Zen API key)
  POST http://apisix:9080/zen/v1/chat/completions

APISIX key-auth plugin:
  Validates "opencode-gateway-key" (the gateway consumer key)
  NOT the Zen key. Two different keys.

APISIX upstream:
  Forwards to https://opencode.ai/zen/v1/chat/completions
  with the original Authorization header (which contains the
  real Zen API key that opencode put there)

Result:
  - Client auth: APISIX key-auth (gateway key)
  - Upstream auth: Zen API key (from opencode config)
```

### 4.4 SSE Streaming Path

When `stream: true` is in the request body:

1. opencode sends `POST /zen/v1/chat/completions` with `"stream": true`
2. APISIX `proxy-buffering` plugin disables NGINX buffering for this route
3. Zen responds with `Content-Type: text/event-stream`
4. APISIX passes SSE chunks through in real-time via `body_filter`
5. `redact` plugin scans SSE chunks for PII in `delta.content` fields
6. `http-logger` captures the final response metadata
7. opencode's AI SDK parses the SSE stream

---

## 5. Telemetry and Observability

### 5.1 Metrics (Prometheus)

The `prometheus` plugin exports metrics per route. Scrape endpoint:
`http://apisix:9099/apisix/prometheus/metrics`.

### 5.2 Telemetry Logging (http-logger to Vector to ClickHouse)

The `http-logger` plugin sends a JSON log entry to Vector for every
request/response. Vector parses and inserts into ClickHouse.

Log entry format (sent to Vector):
```json
{
  "provider": "opencode-zen",
  "model": "big-pickle",
  "stream": true,
  "method": "POST",
  "uri": "/zen/v1/chat/completions",
  "status": 200,
  "latency": 1234
}
```

Vector pipeline (`conf/vector.toml`):
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
"""

[sinks.clickhouse_request_log]
type = "clickhouse"
inputs = ["parse_log"]
endpoint = "http://clickhouse:8123"
database = "llm_gateway"
table = "request_log"
skip_unknown_fields = true
```

### 5.3 Rate Limiting (ai-rate-limiting)

The `ai-rate-limiting` plugin reads the `model` field from the request
body and enforces per-model limits.

### 5.4 PII Redaction (redact plugin)

Custom Lua plugin. Runs in `access` phase (request body) and
`body_filter` phase (response body, including SSE chunks).

See `PLUGIN-REDACT-LUA.md` for full plugin spec.

---

## 6. Integration Summary

### What We Build

1. **APISIX route**: single route `/zen/*` to `opencode.ai:443` with
   the full plugin stack (key-auth, ai-rate-limiting, prometheus,
   http-logger, proxy-buffering, redact).
2. **opencode config**: single custom provider with `baseURL` pointing
   to APISIX. `npm` is `@ai-sdk/openai-compatible`. `apiKey` is the
   real Zen key.
3. **Telemetry pipeline**: APISIX `http-logger` to Vector to ClickHouse.
   Prometheus scrapes APISIX metrics endpoint.
4. **PII redaction**: custom Lua `redact` plugin on the Zen route.
5. **Rate limiting**: `ai-rate-limiting` plugin, per-model RPM.
6. **SSE pass-through**: `proxy-buffering` plugin with `disable: true`.

### What We Do NOT Build

- No format conversion in APISIX (Zen handles all provider-specific
  wire format negotiation).
- No direct connections to individual LLM providers (OpenAI, Anthropic,
  Google, etc.). Zen is the only upstream.
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
 6. APISIX key-auth validates gateway key
 7. APISIX ai-rate-limiting checks model RPM
 8. APISIX redact scans request body for PII
 9. APISIX relays to OpenCode Zen (https://opencode.ai/zen/v1/...)
10. Zen routes to the underlying LLM provider
11. Provider responds (JSON or SSE stream)
12. APISIX proxy-buffering passes SSE through unbuffered
13. APISIX redact scans response for PII (re-hydrate tokens)
14. APISIX prometheus records metrics
15. APISIX http-logger sends log to Vector -> ClickHouse
16. opencode AI SDK parses response/SSE
17. opencode SessionProcessor builds message parts
18. Client receives response
```

---

## 7. opencode Server API Reference

The `opencode serve` command runs an HTTP server (default `:4096`) with
an OpenAPI 3.1 spec at `GET /doc`. All endpoints below are from the
v1.17.13 server docs. This is the opencode CLI's own server API, NOT
the Zen upstream API.

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
    "providerID": "string (e.g. \"gateway\")",
    "modelID": "string (e.g. \"big-pickle\")"
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
      "providerID": "gateway",
      "modelID": "big-pickle"
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
- `gateway/big-pickle` (our custom provider via APISIX to Zen)
- `anthropic/claude-sonnet-4-5` (direct Anthropic)
- `opencode/gpt-5.1-codex` (OpenCode Zen direct)

### 8.3 Model Resolution Priority

1. `--model` CLI flag (e.g., `-m gateway/big-pickle`)
2. `model` key in `opencode.json` config
3. Last used model (persisted)
4. First model by internal priority

### 8.4 Custom Provider Configuration

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "<provider-id>": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Display Name",
      "options": {
        "baseURL": "http://apisix:9080/zen/v1",
        "apiKey": "gateway-api-key",
        "headers": { "X-Custom-Header": "value" }
      },
      "models": {
        "<model-id>": {
          "name": "Display Name",
          "limit": { "context": 128000, "output": 65536 },
          "cost": { "input": 0, "output": 0 },
          "options": { "temperature": 0.7 }
        }
      }
    }
  },
  "model": "<provider-id>/<model-id>"
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
POST /zen/v1/chat/completions
Authorization: Bearer <zen-api-key>
Content-Type: application/json

{
  "model": "big-pickle",
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

APISIX sees this format. It does not parse or convert it. It relays the
HTTP request as-is to Zen. The only body parsing APISIX does is:
- `ai-rate-limiting`: reads `model` field
- `redact`: reads `messages[].content` text fields
- `http-logger`: reads `model` and `stream` fields for log metadata

### 9.3 Zen Provider Compatibility Matrix

All models on Zen are accessible through the gateway. The endpoint
depends on the model's native format:

| Model Family | Native Format | Zen Endpoint | AI SDK Package |
|--------------|--------------|--------------|----------------|
| GPT 5.x | OpenAI Responses | `/v1/responses` | `@ai-sdk/openai` |
| Claude | Anthropic Messages | `/v1/messages` | `@ai-sdk/anthropic` |
| Gemini | Google native | `/v1/models/{id}` | `@ai-sdk/google` |
| DeepSeek, MiniMax, GLM, Kimi, Grok | OpenAI Chat Completions | `/v1/chat/completions` | `@ai-sdk/openai-compatible` |
| Free models (Big Pickle, MiMo, Nemotron, North Mini, DeepSeek Flash) | OpenAI Chat Completions | `/v1/chat/completions` | `@ai-sdk/openai-compatible` |

For the gateway, all free models use `/v1/chat/completions` and
`@ai-sdk/openai-compatible`. A single APISIX route covers them all.

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
