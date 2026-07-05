# OpenCode Integration

**Project:** WORKSPACE-GATEWAY
**Platform:** Apache APISIX 3.17.0, opencode v1.17.13+
**Status:** Integration specification
**Date:** 2026-07-05

## 1. Architecture: APISIX as LLM Relay for opencode

opencode performs ALL format conversion internally (SessionV1 parts to
AI SDK ModelMessage to provider-native wire format). By the time the HTTP
request leaves opencode's process, it is standard HTTP with a JSON body
in the upstream provider's native format. APISIX sits between opencode's
`fetch()` and the upstream LLM provider, acting as a transparent relay
that intercepts zero format logic.

```
opencode (Bun/TypeScript)
  |  AI SDK v5 does ALL conversion:
  |  SessionV1 -> ModelMessage[] -> provider-native JSON
  |
  |  fetch() sends standard HTTP to baseURL
  v
APISIX (port 9080)
  |  Receives provider-native HTTP (any format, doesn't care)
  |  Plugins: key-auth, ai-rate-limiting, prometheus, http-logger,
  |           proxy-buffering(off), redact, semantic-cache(v2)
  |  Relays to upstream, passes SSE back unchanged
  v
LLM Provider (api.openai.com, api.anthropic.com, etc.)
```

**What APISIX touches:** HTTP headers (key injection), JSON body (rate
limiting reads `model` field, redact scans `messages[].content`), SSE
pass-through (buffering disabled), response logging (token usage,
latency, status).

**What APISIX does NOT touch:** Request body format (Chat Completions,
Anthropic Messages, Gemini, whatever), SSE event structure (beyond
text-field redaction), tool call schemas, reasoning/thinking fields,
provider-specific headers (anthropic-beta, etc.).

---

## 2. opencode Server API Reference

The `opencode serve` command runs an HTTP server (default `:4096`) with
an OpenAPI 3.1 spec at `GET /doc`. All endpoints below are from the v1.17.13
server docs.

### 2.1 Authentication

HTTP Basic Auth. Enabled when `OPENCODE_SERVER_PASSWORD` is set.

| Header | Format |
|--------|--------|
| `Authorization` | `Basic base64(username:password)` |
| Query `?auth_token=` | `base64(username:password)` |

Username defaults to `opencode`. Override with `OPENCODE_SERVER_USERNAME`.

No auth when password is unset (default). No bearer tokens, no API keys,
no session cookies.

### 2.2 Global

| Method | Path | Description | Response |
|--------|------|-------------|----------|
| `GET` | `/global/health` | Server health and version | `{ healthy: true, version: string }` |
| `GET` | `/global/event` | Global events (SSE stream) | Event stream |

### 2.3 Project

| Method | Path | Description | Response |
|--------|------|-------------|----------|
| `GET` | `/project` | List all projects | `Project[]` |
| `GET` | `/project/current` | Get the current project | `Project` |

### 2.4 Path and VCS

| Method | Path | Description | Response |
|--------|------|-------------|----------|
| `GET` | `/path` | Get the current path | `Path` |
| `GET` | `/vcs` | Get VCS info for current project | `VcsInfo` |

### 2.5 Instance

| Method | Path | Description | Response |
|--------|------|-------------|----------|
| `POST` | `/instance/dispose` | Dispose the current instance | `boolean` |

### 2.6 Config

| Method | Path | Description | Response |
|--------|------|-------------|----------|
| `GET` | `/config` | Get config info | `Config` |
| `PATCH` | `/config` | Update config | `Config` |
| `GET` | `/config/providers` | List providers and default models | `{ providers: Provider[], default: {[k]: string} }` |

### 2.7 Provider

| Method | Path | Description | Response |
|--------|------|-------------|----------|
| `GET` | `/provider` | List all providers | `{ all: Provider[], default: {...}, connected: string[] }` |
| `GET` | `/provider/auth` | Get provider auth methods | `{ [providerID]: ProviderAuthMethod[] }` |
| `POST` | `/provider/{id}/oauth/authorize` | Authorize provider via OAuth | `ProviderAuthAuthorization` |
| `POST` | `/provider/{id}/oauth/callback` | Handle OAuth callback | `boolean` |

### 2.8 Sessions

| Method | Path | Description | Body / Query | Response |
|--------|------|-------------|--------------|----------|
| `GET` | `/session` | List all sessions | | `Session[]` |
| `POST` | `/session` | Create a new session | `{ parentID?, title? }` | `Session` |
| `GET` | `/session/status` | Get status for all sessions | | `{ [sessionID]: SessionStatus }` |
| `GET` | `/session/:id` | Get session details | | `Session` |
| `DELETE` | `/session/:id` | Delete session and all data | | `boolean` |
| `PATCH` | `/session/:id` | Update session properties | `{ title? }` | `Session` |
| `GET` | `/session/:id/children` | Get child sessions | | `Session[]` |
| `GET` | `/session/:id/todo` | Get todo list for session | | `Todo[]` |
| `POST` | `/session/:id/init` | Analyze app, create AGENTS.md | `{ messageID, providerID, modelID }` | `boolean` |
| `POST` | `/session/:id/fork` | Fork session at a message | `{ messageID? }` | `Session` |
| `POST` | `/session/:id/abort` | Abort a running session | | `boolean` |
| `POST` | `/session/:id/share` | Share a session | | `Session` |
| `DELETE` | `/session/:id/share` | Unshare a session | | `Session` |
| `GET` | `/session/:id/diff` | Get diff for this session | `?messageID=` | `FileDiff[]` |
| `POST` | `/session/:id/summarize` | Summarize the session | `{ providerID, modelID }` | `boolean` |
| `POST` | `/session/:id/revert` | Revert a message | `{ messageID, partID? }` | `boolean` |
| `POST` | `/session/:id/unrevert` | Restore all reverted messages | | `boolean` |
| `POST` | `/session/:id/permissions/:permissionID` | Respond to permission request | `{ response, remember? }` | `boolean` |

### 2.9 Messages (the core prompt endpoint)

| Method | Path | Description | Response |
|--------|------|-------------|----------|
| `GET` | `/session/:id/message` | List messages in session | `{ info: Message, parts: Part[] }[]` |
| `POST` | `/session/:id/message` | Send a message, wait for response | `{ info: Message, parts: Part[] }` |
| `GET` | `/session/:id/message/:messageID` | Get message details | `{ info: Message, parts: Part[] }` |
| `POST` | `/session/:id/prompt_async` | Send a message asynchronously | `204 No Content` |
| `POST` | `/session/:id/command` | Execute a slash command | `{ info: Message, parts: Part[] }` |
| `POST` | `/session/:id/shell` | Run a shell command | `{ info: Message, parts: Part[] }` |

#### POST /session/:id/message Request Body

```json
{
  "messageID": "string (optional, for replies)",
  "model": {
    "providerID": "string (e.g. \"anthropic\")",
    "modelID": "string (e.g. \"claude-sonnet-4-5\")"
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

When `noReply: true`, the message is injected as context without
triggering an AI response. Returns the user message only.

#### POST /session/:id/message Response

```json
{
  "info": {
    "id": "msg_abc123",
    "sessionID": "sess_xyz789",
    "role": "assistant",
    "time": 1720195200,
    "model": {
      "providerID": "anthropic",
      "modelID": "claude-sonnet-4-5"
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

### 2.10 Commands

| Method | Path | Description | Response |
|--------|------|-------------|----------|
| `GET` | `/command` | List all commands | `Command[]` |

### 2.11 Files

| Method | Path | Description | Query | Response |
|--------|------|-------------|-------|----------|
| `GET` | `/find` | Search for text in files | `?pattern=` | Match objects with `path`, `lines`, `line_number`, `absolute_offset`, `submatches` |
| `GET` | `/find/file` | Find files/dirs by name | `?query=&type=&directory=&limit=` | `string[]` (paths) |
| `GET` | `/find/symbol` | Find workspace symbols | `?query=` | `Symbol[]` |
| `GET` | `/file` | List files and directories | `?path=` | `FileNode[]` |
| `GET` | `/file/content` | Read a file | `?path=` | `FileContent` |
| `GET` | `/file/status` | Get status for tracked files | | `File[]` |

### 2.12 Tools (Experimental)

| Method | Path | Description | Response |
|--------|------|-------------|----------|
| `GET` | `/experimental/tool/ids` | List all tool IDs | `ToolIDs` |
| `GET` | `/experimental/tool` | List tools with JSON schemas | `?provider=&model=` | `ToolList` |

### 2.13 LSP, Formatters and MCP

| Method | Path | Description | Response |
|--------|------|-------------|----------|
| `GET` | `/lsp` | Get LSP server status | `LSPStatus[]` |
| `GET` | `/formatter` | Get formatter status | `FormatterStatus[]` |
| `GET` | `/mcp` | Get MCP server status | `{ [name]: MCPStatus }` |
| `POST` | `/mcp` | Add MCP server dynamically | `{ name, config }` |

### 2.14 Agents

| Method | Path | Description | Response |
|--------|------|-------------|----------|
| `GET` | `/agent` | List all available agents | `Agent[]` |

### 2.15 Logging

| Method | Path | Description | Body | Response |
|--------|------|-------------|------|----------|
| `POST` | `/log` | Write log entry | `{ service, level, message, extra? }` | `boolean` |

### 2.16 TUI Control

| Method | Path | Description | Response |
|--------|------|-------------|----------|
| `POST` | `/tui/append-prompt` | Append text to the prompt | `boolean` |
| `POST` | `/tui/open-help` | Open the help dialog | `boolean` |
| `POST` | `/tui/open-sessions` | Open the session selector | `boolean` |
| `POST` | `/tui/open-themes` | Open the theme selector | `boolean` |
| `POST` | `/tui/open-models` | Open the model selector | `boolean` |
| `POST` | `/tui/submit-prompt` | Submit the current prompt | `boolean` |
| `POST` | `/tui/clear-prompt` | Clear the prompt | `boolean` |
| `POST` | `/tui/execute-command` | Execute a command `{ command }` | `boolean` |
| `POST` | `/tui/show-toast` | Show toast `{ title?, message, variant }` | `boolean` |
| `GET` | `/tui/control/next` | Wait for next control request | Control request object |
| `POST` | `/tui/control/response` | Respond to a control request `{ body }` | `boolean` |

### 2.17 Auth

| Method | Path | Description | Body | Response |
|--------|------|-------------|------|----------|
| `PUT` | `/auth/:id` | Set auth credentials for a provider | Provider-specific | `boolean` |

### 2.18 Events (SSE)

| Method | Path | Description | Response |
|--------|------|-------------|----------|
| `GET` | `/event` | Server-sent events stream | SSE stream |

First event is `server.connected`, then bus events. 10-second heartbeat
(`server.heartbeat`). Response headers: `Cache-Control: no-cache,
no-transform`, `X-Accel-Buffering: no`, `Content-Type: text/event-stream`.

Events include: `session.updated`, `session.created`, `session.deleted`,
`session.idle`, `session.error`, `message.updated`, `message.removed`,
`message.part.updated`, `message.part.removed`, `tool.execute.before`,
`tool.execute.after`, `permission.asked`, `permission.replied`,
`file.edited`, `lsp.updated`, `server.connected`, `server.heartbeat`,
`server.instance.disposed`.

### 2.19 Docs

| Method | Path | Description | Response |
|--------|------|-------------|----------|
| `GET` | `/doc` | OpenAPI 3.1 specification | HTML page with OpenAPI spec |

---

## 3. opencode Provider and Model Selection

### 3.1 How Providers Work

opencode uses the Vercel AI SDK v5 (`ai` package). Each provider is an
AI SDK factory that returns a `LanguageModelV3` interface. The factory
handles HTTP communication with the upstream LLM API.

**Three-tier provider loading:**

1. **Bundled** (in opencode binary): `@ai-sdk/openai`,
   `@ai-sdk/anthropic`, `@ai-sdk/google`, `@ai-sdk/azure`,
   `@ai-sdk/amazon-bedrock`, `@ai-sdk/openai-compatible`,
   `@openrouter/ai-sdk-provider`, and 15+ more.
2. **Custom loaders** (per-provider quirks): Anthropic beta headers,
   Bedrock SigV4, Vertex ADC, Azure URL construction, Copilot device
   flow, etc.
3. **Dynamic NPM import**: for any provider not bundled, opencode
   installs the npm package at runtime and imports it.

### 3.2 Model ID Format

Models are identified as `providerID/modelID`. Examples:
- `anthropic/claude-sonnet-4-5`
- `openai/gpt-5`
- `opencode/gpt-5.1-codex` (OpenCode Zen)
- `ollama/llama2` (custom provider)

### 3.3 Model Resolution Priority

1. `--model` CLI flag (e.g., `-m anthropic/claude-sonnet-4-5`)
2. `model` key in `opencode.json` config
3. Last used model (persisted)
4. First model by internal priority

### 3.4 Custom Provider Configuration

Any provider can be configured in `opencode.json`. The key fields:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "<provider-id>": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Display Name",
      "options": {
        "baseURL": "http://apisix:9080/v1",
        "apiKey": "gateway-api-key",
        "headers": { "X-Custom-Header": "value" }
      },
      "models": {
        "<model-id>": {
          "name": "Display Name",
          "limit": { "context": 128000, "output": 65536 },
          "cost": { "input": 0.003, "output": 0.015 },
          "options": { "temperature": 0.7 }
        }
      }
    }
  },
  "model": "<provider-id>/<model-id>"
}
```

The `npm` field selects which AI SDK factory builds the HTTP client.
`@ai-sdk/openai-compatible` speaks OpenAI Chat Completions format.
`@ai-sdk/anthropic` speaks Anthropic Messages format. The `baseURL`
is where opencode sends HTTP requests. `apiKey` is injected as
`Authorization: Bearer <key>` by the AI SDK.

### 3.5 Provider `baseURL` Override

Every provider accepts `options.baseURL`. This is the primary mechanism
for routing through APISIX. Set `baseURL` to the APISIX route and opencode
will send all requests for that provider to APISIX instead of the
provider's real endpoint.

### 3.6 Variable Substitution

`baseURL` supports `${VAR}` substitution from environment variables:

```json
{
  "options": {
    "baseURL": "http://${APISIX_HOST}:${APISIX_PORT}/v1"
  }
}
```

### 3.7 Auth Credential Storage

Credentials set via `/connect` command are stored in
`~/.local/share/opencode/auth.json`. API keys can also be set via
`options.apiKey` in config, environment variables, or `{file:path}`
substitution.

---

## 4. APISIX Relay Configuration

### 4.1 Approach: Per-Provider APISIX Routes

Create one APISIX route per upstream LLM provider. Each route relays to
the provider's real endpoint and applies the full plugin stack. opencode
is configured with one custom provider per APISIX route.

```
opencode
  |
  |-- provider "gw-openai"    -> http://apisix:9080/openai/*    -> api.openai.com
  |-- provider "gw-anthropic" -> http://apisix:9080/anthropic/* -> api.anthropic.com
  |-- provider "gw-together"  -> http://apisix:9080/together/*  -> api.together.xyz
  |-- provider "gw-groq"      -> http://apisix:9080/groq/*      -> api.groq.com
  \-- provider "gw-openrouter"-> http://apisix:9080/openrouter/*-> openrouter.ai/api
```

### 4.2 opencode Configuration

```jsonc
// opencode.json
{
  "$schema": "https://opencode.ai/config.json",

  "provider": {
    // OpenAI: uses @ai-sdk/openai (Responses API) natively.
    // Point baseURL at APISIX. APISIX relays to api.openai.com.
    "gw-openai": {
      "npm": "@ai-sdk/openai",
      "name": "OpenAI (via Gateway)",
      "options": {
        "baseURL": "http://apisix:9080/openai/v1",
        "apiKey": "{env:OPENAI_API_KEY}"
      },
      "models": {
        "gpt-5": { "name": "GPT-5" },
        "gpt-5.1-codex": { "name": "GPT-5.1 Codex" },
        "gpt-5-mini": { "name": "GPT-5 Mini" }
      }
    },

    // Anthropic: uses @ai-sdk/anthropic (Messages API) natively.
    // Point baseURL at APISIX. APISIX relays to api.anthropic.com.
    "gw-anthropic": {
      "npm": "@ai-sdk/anthropic",
      "name": "Anthropic (via Gateway)",
      "options": {
        "baseURL": "http://apisix:9080/anthropic/v1",
        "apiKey": "{env:ANTHROPIC_API_KEY}"
      },
      "models": {
        "claude-sonnet-4-5": { "name": "Claude Sonnet 4.5" },
        "claude-opus-4-5": { "name": "Claude Opus 4.5" }
      }
    },

    // OpenAI-compatible providers: use @ai-sdk/openai-compatible.
    // APISIX relays Chat Completions to the upstream.
    "gw-together": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Together AI (via Gateway)",
      "options": {
        "baseURL": "http://apisix:9080/together/v1",
        "apiKey": "{env:TOGETHER_API_KEY}"
      },
      "models": {
        "deepseek-v3": { "name": "DeepSeek V3" }
      }
    },

    "gw-groq": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Groq (via Gateway)",
      "options": {
        "baseURL": "http://apisix:9080/groq/v1",
        "apiKey": "{env:GROQ_API_KEY}"
      },
      "models": {
        "llama-4-scout": { "name": "Llama 4 Scout" }
      }
    },

    "gw-openrouter": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "OpenRouter (via Gateway)",
      "options": {
        "baseURL": "http://apisix:9080/openrouter/v1",
        "apiKey": "{env:OPENROUTER_API_KEY}"
      },
      "models": {
        "anthropic/claude-sonnet-4-5": { "name": "Claude Sonnet 4.5 (OR)" },
        "google/gemini-3-pro": { "name": "Gemini 3 Pro (OR)" }
      }
    }
  },

  // Default model
  "model": "gw-anthropic/claude-sonnet-4-5",

  // Small model for title generation etc.
  "small_model": "gw-openai/gpt-5-mini",

  // Disable sharing (enterprise)
  "share": "disabled"
}
```

### 4.3 APISIX Route Configuration (apisix.yaml)

```yaml
# APISIX standalone YAML mode routes

routes:
  # ---- OpenAI ----
  - id: relay-openai
    uri: /openai/*
    upstream:
      type: roundrobin
      scheme: https
      nodes:
        "api.openai.com:443": 1
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
        endpoint: "http://vector:8888/llm-log"
        content_type: "application/json"
        log_format:
          provider: "openai"
          model: "$request_body.model"
          stream: "$request_body.stream"
          method: "$request_method"
          uri: "$uri"
          status: "$status"
          latency: "$upstream_latency_ms"
      proxy-buffering:
        disable: true
      proxy-rewrite:
        regex_uri: ["^/openai/(.*)", "/$1"]
      redact:
        patterns_file: "/usr/local/apisix/conf/redact-patterns.json"

  # ---- Anthropic ----
  - id: relay-anthropic
    uri: /anthropic/*
    upstream:
      type: roundrobin
      scheme: https
      nodes:
        "api.anthropic.com:443": 1
    plugins:
      key-auth: {}
      ai-rate-limiting:
        model: "$request_body.model"
        limit: 500
        time_window: 60
        rejected_code: 429
      prometheus:
        prefer_name: true
      http-logger:
        endpoint: "http://vector:8888/llm-log"
        content_type: "application/json"
        log_format:
          provider: "anthropic"
          model: "$request_body.model"
          stream: "$request_body.stream"
      proxy-buffering:
        disable: true
      proxy-rewrite:
        regex_uri: ["^/anthropic/(.*)", "/$1"]
      redact:
        patterns_file: "/usr/local/apisix/conf/redact-patterns.json"

  # ---- Together AI ----
  - id: relay-together
    uri: /together/*
    upstream:
      type: roundrobin
      scheme: https
      nodes:
        "api.together.xyz:443": 1
    plugins:
      key-auth: {}
      ai-rate-limiting:
        model: "$request_body.model"
        limit: 500
        time_window: 60
      prometheus: { prefer_name: true }
      http-logger:
        endpoint: "http://vector:8888/llm-log"
        content_type: "application/json"
        log_format:
          provider: "together"
          model: "$request_body.model"
      proxy-buffering: { disable: true }
      proxy-rewrite:
        regex_uri: ["^/together/(.*)", "/$1"]
      redact:
        patterns_file: "/usr/local/apisix/conf/redact-patterns.json"

  # ---- Groq ----
  - id: relay-groq
    uri: /groq/*
    upstream:
      type: roundrobin
      scheme: https
      nodes:
        "api.groq.com:443": 1
    plugins:
      key-auth: {}
      ai-rate-limiting:
        model: "$request_body.model"
        limit: 1000
        time_window: 60
      prometheus: { prefer_name: true }
      http-logger:
        endpoint: "http://vector:8888/llm-log"
        content_type: "application/json"
        log_format:
          provider: "groq"
          model: "$request_body.model"
      proxy-buffering: { disable: true }
      proxy-rewrite:
        regex_uri: ["^/groq/(.*)", "/$1"]
      redact:
        patterns_file: "/usr/local/apisix/conf/redact-patterns.json"

  # ---- OpenRouter ----
  - id: relay-openrouter
    uri: /openrouter/*
    upstream:
      type: roundrobin
      scheme: https
      nodes:
        "openrouter.ai:443": 1
    plugins:
      key-auth: {}
      ai-rate-limiting:
        model: "$request_body.model"
        limit: 500
        time_window: 60
      prometheus: { prefer_name: true }
      http-logger:
        endpoint: "http://vector:8888/llm-log"
        content_type: "application/json"
        log_format:
          provider: "openrouter"
          model: "$request_body.model"
      proxy-buffering: { disable: true }
      proxy-rewrite:
        regex_uri: ["^/openrouter/(.*)", "/$1"]
      redact:
        patterns_file: "/usr/local/apisix/conf/redact-patterns.json"

# Consumer keys for key-auth
consumers:
  - id: opencode
    key_auth_credentials:
      - key: "opencode-gateway-key"
```

### 4.4 What Each Plugin Does on the Relay Path

| Plugin | Phase | What It Does |
|--------|-------|--------------|
| `key-auth` | `access` | Validates client API key. opencode sends `Authorization: Bearer <key>`. APISIX checks against consumer registry. |
| `ai-rate-limiting` | `access` | Reads `model` from request body. Enforces per-model RPM/TPM limits. Returns `429` on exceed. |
| `proxy-rewrite` | `access` | Strips the provider prefix from the URI (`/openai/v1/chat/completions` to `/v1/chat/completions`). |
| `proxy-buffering` | `access` | Disables NGINX proxy buffering for this route. Critical for SSE streaming. Without this, SSE chunks queue in NGINX buffer and streaming breaks. |
| `redact` | `access` + `body_filter` | Scans request body JSON for PII patterns (SSN, email, phone, etc.) before relay. Scans response body (including SSE chunks) for PII in `content`/`text` fields. Stores PII Map in `ctx` for re-hydration. |
| `prometheus` | `log` | Exports HTTP metrics: request count, latency histogram, status code distribution, upstream latency. Scraped by Prometheus at `/apisix/prometheus/metrics`. |
| `http-logger` | `log` | Sends structured JSON log to Vector at `http://vector:8888/llm-log`. Vector parses and inserts into ClickHouse for billing/analytics. Log includes provider, model, stream flag, status, latency. |

### 4.5 API Key Flow

```
opencode config:
  options.apiKey = "{env:OPENAI_API_KEY}"  (real upstream key)

opencode sends:
  Authorization: Bearer sk-real-upstream-key
  POST http://apisix:9080/openai/v1/chat/completions

APISIX key-auth plugin:
  Validates "opencode-gateway-key" (the gateway consumer key)
  NOT the upstream key. Two different keys.

APISIX proxy-rewrite / upstream:
  Forwards to api.openai.com with the original Authorization header
  (which contains the real upstream key that opencode put there)

Result:
  - Client auth: APISIX key-auth (gateway key)
  - Upstream auth: original provider API key (from opencode config)
```

If you want APISIX to inject the upstream key instead of opencode:

```yaml
plugins:
  proxy-rewrite:
    regex_uri: ["^/openai/(.*)", "/$1"]
    headers:
      set:
        Authorization: "Bearer sk-injected-by-gateway"
```

Then opencode config sets `apiKey` to the gateway key, and APISIX
replaces it with the real upstream key before relaying.

### 4.6 SSE Streaming Path

When `stream: true` is in the request body:

1. opencode sends `POST /openai/v1/chat/completions` with `"stream": true`
2. APISIX `proxy-buffering` plugin disables NGINX buffering for this route
3. Upstream responds with `Content-Type: text/event-stream`
4. APISIX passes SSE chunks through in real-time via `body_filter`
5. `redact` plugin scans each SSE chunk for PII in `delta.content` fields
6. `http-logger` captures the final response metadata (status, latency, token usage if in trailing chunk)
7. opencode's AI SDK parses the SSE stream and yields normalized events

The `X-Accel-Buffering: no` header is already set by opencode's server
when it streams to clients. For the upstream relay, `proxy-buffering`
plugin with `disable: true` achieves the same effect.

### 4.7 Alternative: Single OpenAI-Compatible Provider

If all upstreams are OpenAI-compatible, use a single provider and a
single route. APISIX uses `ai-proxy` plugin with model-to-provider
mapping:

```jsonc
// opencode.json (simplified)
{
  "provider": {
    "gateway": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "APISIX Gateway",
      "options": {
        "baseURL": "http://apisix:9080/v1",
        "apiKey": "gateway-key"
      },
      "models": {
        "gpt-5": { "name": "GPT-5" },
        "claude-sonnet-4-5": { "name": "Claude Sonnet 4.5" },
        "deepseek-v3": { "name": "DeepSeek V3" }
      }
    }
  },
  "model": "gateway/gpt-5"
}
```

```yaml
# apisix.yaml (single route with ai-proxy)
routes:
  - id: llm-gateway
    uri: /v1/chat/completions
    methods: [POST]
    plugins:
      key-auth: {}
      ai-proxy:
        provider: openai
        api_key: "$env://OPENAI_API_KEY"
        model: "$request_body.model"
        endpoint: "https://api.openai.com"
        # For multiple providers, use ai-proxy-multi
      ai-rate-limiting:
        model: "$request_body.model"
        limit: 1000
        time_window: 60
      prometheus: { prefer_name: true }
      http-logger:
        endpoint: "http://vector:8888/llm-log"
        content_type: "application/json"
      proxy-buffering: { disable: true }
      redact:
        patterns_file: "/usr/local/apisix/conf/redact-patterns.json"

  - id: llm-models
    uri: /v1/models
    methods: [GET]
    plugins:
      key-auth: {}
    upstream:
      type: roundrobin
      nodes:
        "api.openai.com:443": 1
```

This works when ALL upstreams speak OpenAI Chat Completions. For
providers that do not (Anthropic native, Bedrock, Vertex), use the
per-provider route approach from section 4.3.

---

## 5. Telemetry and Stats Hooks

### 5.1 Metrics (Prometheus)

The `prometheus` plugin exports the following metrics per route:

| Metric | Type | Labels |
|--------|------|--------|
| `apisix_http_status_code` | counter | `route`, `status` |
| `apisix_http_latency` | histogram | `route`, `latency_type` (upstream, total) |
| `apisix_request_total` | counter | `route` |
| `apisix_upstream_latency_ms` | histogram | `route`, `provider` (from log_format) |

Scrape endpoint: `http://apisix:9099/apisix/prometheus/metrics`.

Prometheus scrape config:
```yaml
scrape_configs:
  - job_name: apisix
    static_configs:
      - targets: ["apisix:9099"]
    metrics_path: /apisix/prometheus/metrics
```

### 5.2 Telemetry Logging (http-logger to Vector to ClickHouse)

The `http-logger` plugin sends a JSON log entry to Vector for every
request/response. Vector parses and inserts into ClickHouse.

Log entry format (sent to Vector):
```json
{
  "provider": "openai",
  "model": "gpt-5",
  "stream": true,
  "method": "POST",
  "uri": "/openai/v1/chat/completions",
  "status": 200,
  "latency": 1234,
  "request_size": 5678,
  "response_size": 9012,
  "client_ip": "10.0.0.1",
  "timestamp": "2026-07-05T12:00:00Z"
}
```

Vector pipeline (`vector.toml`):
```toml
[sources.apisix_llm]
type = "http_server"
address = "0.0.0.0:8888"
path = "/llm-log"
encoding = "json"

[sinks.clickhouse_llm]
type = "clickhouse"
inputs = ["apisix_llm"]
endpoint = "http://clickhouse:8123"
database = "llm_gateway"
table = "request_log"
skip_unknown_fields = true
```

ClickHouse table (from `DEPLOYMENT.md`):
```sql
CREATE TABLE llm_gateway.request_log (
  timestamp DateTime64(3),
  provider LowCardinality(String),
  model LowCardinality(String),
  stream Bool,
  method LowCardinality(String),
  uri String,
  status UInt16,
  latency_ms UInt32,
  request_size UInt32,
  response_size UInt32,
  client_ip IPv4,
  api_key_id String
) ENGINE = MergeTree()
ORDER BY (provider, model, timestamp)
TTL timestamp + INTERVAL 13 MONTHS;
```

### 5.3 Rate Limiting (ai-rate-limiting)

The `ai-rate-limiting` plugin reads the `model` field from the request
body and enforces per-model limits. Configuration:

```yaml
ai-rate-limiting:
  model: "$request_body.model"
  limit: 1000        # requests per time window
  time_window: 60    # seconds
  rejected_code: 429
  rejected_msg: "Rate limit exceeded for model"
```

Supports RPM (requests per minute) and TPM (tokens per minute, if
upstream returns usage in response).

### 5.4 PII Redaction (redact plugin)

Custom Lua plugin. Runs in `access` phase (request body) and
`body_filter` phase (response body, including SSE chunks).

Request-side: parses JSON body, scans `messages[].content` text fields
against PCRE patterns from `redact-patterns.json`. Replaces matches with
tokens (`[REDACTED_EMAIL_1]`). Stores original-to-token mapping in
`ctx.redact_pii_map`.

Response-side: scans `choices[].delta.content` (SSE) or
`choices[].message.content` (non-streaming) for tokens. Replaces tokens
with original values (re-hydration). This ensures the LLM sees redacted
input and the client sees un-redacted output.

See `PLUGIN-REDACT-LUA.md` for full plugin spec.

### 5.5 Semantic Cache (v2)

Custom Lua plugin. Checks Redis VSS for semantically similar prior
requests. On HIT, returns cached response (synthesizes SSE if original
was streaming). On MISS, relays to upstream and caches the response.

See `PLUGIN-SEMANTIC-CACHE.md` for full plugin spec.

### 5.6 Failover (ai-proxy-multi)

For providers with multiple endpoints (e.g., OpenAI primary + Azure
fallback), use `ai-proxy-multi`:

```yaml
ai-proxy-multi:
  providers:
    - openai:
        api_key: "$env://OPENAI_API_KEY"
        endpoint: "https://api.openai.com"
    - azure:
        api_key: "$env://AZURE_API_KEY"
        endpoint: "https://my-resource.openai.azure.com"
  failover:
    retry: 2
    timeout: 30
```

See `BUILTIN-PLUGINS.md` for full config.

---

## 6. OpenAI API Compatibility Assessment

### 6.1 opencode Server API vs OpenAI API

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
| Structured output | `response_format: { type: "json_schema" }` | `format: { type: "json_schema", schema }` |
| Token usage | `usage: { prompt_tokens, completion_tokens }` | `info.tokens: { input, output, reasoning }` |
| Cost | Not returned | `info.cost: { input, output, total }` |

### 6.2 opencode's AI SDK Wire Format (what APISIX sees)

When opencode uses `@ai-sdk/openai-compatible`, it sends standard OpenAI
Chat Completions to the `baseURL`:

```
POST /v1/chat/completions
Authorization: Bearer <api-key>
Content-Type: application/json

{
  "model": "gpt-5",
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

When opencode uses `@ai-sdk/openai` (built-in OpenAI provider), it sends
to the Responses API:

```
POST /v1/responses
Authorization: Bearer <api-key>
Content-Type: application/json

{
  "model": "gpt-5",
  "input": [...],
  "stream": true,
  "reasoning": { "effort": "high" },
  "store": false
}
```

When opencode uses `@ai-sdk/anthropic`, it sends Anthropic Messages:

```
POST /v1/messages
x-api-key: <api-key>
anthropic-version: 2023-06-01
anthropic-beta: interleaved-thinking-2025-05-14
Content-Type: application/json

{
  "model": "claude-sonnet-4-5",
  "messages": [...],
  "max_tokens": 8192,
  "stream": true
}
```

APISIX sees all three formats. It does not parse or convert any of them.
It relays the HTTP request as-is to the upstream. The only body parsing
APISIX does is:
- `ai-rate-limiting`: reads `model` field (present in all formats)
- `redact`: reads `messages[].content` / `input[].content` text fields
- `http-logger`: reads `model` and `stream` fields for log metadata

### 6.3 Provider OpenAI Compatibility Matrix

| Provider | Native Format | OpenAI-Compatible Endpoint | APISIX Relay Approach |
|----------|--------------|---------------------------|---------------------|
| OpenAI | Responses API | Chat Completions (`/v1/chat/completions`) | `@ai-sdk/openai` or `@ai-sdk/openai-compatible` |
| Anthropic | Messages API | No | `@ai-sdk/anthropic` (native) or via OpenRouter |
| Google Gemini | generateContent | Yes (`/v1beta/openai/chat/completions`) | `@ai-sdk/openai-compatible` to Gemini OpenAI endpoint |
| Amazon Bedrock | Native AWS | No | `@ai-sdk/amazon-bedrock` (native) or via OpenRouter |
| Google Vertex | Native | No | `@ai-sdk/google-vertex` (native) or via OpenRouter |
| Azure OpenAI | Chat Completions | Yes | `@ai-sdk/azure` or `@ai-sdk/openai-compatible` |
| Together AI | Chat Completions | Yes | `@ai-sdk/openai-compatible` |
| Groq | Chat Completions | Yes | `@ai-sdk/openai-compatible` |
| DeepSeek | Chat Completions | Yes | `@ai-sdk/openai-compatible` |
| OpenRouter | Chat Completions | Yes (routes to all providers) | `@ai-sdk/openai-compatible` |
| Fireworks AI | Chat Completions | Yes | `@ai-sdk/openai-compatible` |
| Cerebras | Chat Completions | Yes | `@ai-sdk/openai-compatible` |
| Mistral | Chat Completions | Yes | `@ai-sdk/openai-compatible` |
| xAI | Chat Completions | Yes | `@ai-sdk/openai-compatible` |
| Ollama | Chat Completions | Yes | `@ai-sdk/openai-compatible` |
| LM Studio | Chat Completions | Yes | `@ai-sdk/openai-compatible` |
| llama.cpp | Chat Completions | Yes | `@ai-sdk/openai-compatible` |
| NVIDIA NIM | Chat Completions | Yes | `@ai-sdk/openai-compatible` |
| Moonshot AI | Chat Completions | Yes | `@ai-sdk/openai-compatible` |
| MiniMax | Chat Completions | Yes | `@ai-sdk/openai-compatible` |
| OpenCode Zen | Chat Completions | Yes | `@ai-sdk/openai-compatible` |
| OpenCode Go | Chat Completions | Yes | `@ai-sdk/openai-compatible` |

For non-OpenAI-compatible providers (Anthropic native, Bedrock, Vertex),
two options:
1. Use the native AI SDK package with `baseURL` pointing to APISIX.
   APISIX relays the native format. No conversion needed.
2. Use OpenRouter (OpenAI-compatible) as the upstream. APISIX relays
   Chat Completions to OpenRouter, which converts to the native format.

---

## 7. opencode Extensions Beyond OpenAI API

### 7.1 Session Management

opencode is stateful. Sessions persist message history, tool outputs,
file diffs, and todo lists. OpenAI API is stateless (each request is
independent).

| Feature | OpenAI | opencode |
|---------|--------|----------|
| Create session | N/A | `POST /session` |
| List sessions | N/A | `GET /session` |
| Delete session | N/A | `DELETE /session/:id` |
| Fork session | N/A | `POST /session/:id/fork` |
| Revert message | N/A | `POST /session/:id/revert` |
| Share session | N/A | `POST /session/:id/share` |
| Session diff | N/A | `GET /session/:id/diff` |
| Session todos | N/A | `GET /session/:id/todo` |

### 7.2 Agent System

opencode has built-in agents (build, plan) and custom agents. Each agent
has its own system prompt, tool set, and permissions. OpenAI has no
agent concept.

| Feature | OpenAI | opencode |
|---------|--------|----------|
| Built-in agents | N/A | build, plan |
| Custom agents | N/A | config or `.opencode/agents/*.md` |
| Agent-specific tools | N/A | per-agent tool whitelist/blacklist |
| Agent-specific model | N/A | per-agent model override |
| Agent-specific permissions | N/A | per-agent permission rules |
| Subagents | N/A | `@general` subagent invocation |

### 7.3 Tool Execution

opencode executes tools server-side. The LLM calls tools, opencode
executes them, and returns results to the LLM. OpenAI expects the client
to execute tools.

| Feature | OpenAI | opencode |
|---------|--------|----------|
| Tool declaration | Client sends `tools` array | Agent config defines available tools |
| Tool execution | Client-side (function calling) | Server-side (opencode runs the tool) |
| Tool permissions | N/A | `allow` / `ask` / `deny` per tool |
| Built-in tools | N/A | read, write, edit, bash, grep, glob, ls, webfetch, websearch, task, todowrite, question |
| Custom tools | N/A | Plugin-defined tools with Zod schemas |
| MCP tools | N/A | External MCP servers (stdio, HTTP+SSE) |

### 7.4 SSE Event Bus

opencode has a global event bus (`GET /event`) that streams all session
events. OpenAI has per-request SSE only.

| Feature | OpenAI | opencode |
|---------|--------|----------|
| SSE scope | Per-request | Global (all sessions) |
| Heartbeat | None | 10-second `server.heartbeat` |
| Event types | `delta`, `finish` | 20+ event types (session, message, tool, permission, file, lsp) |
| First event | First delta | `server.connected` |
| Connection | Per request | Long-lived (subscribe once, receive all events) |

### 7.5 Message Part Types

opencode messages have rich part types. OpenAI messages are text-only
(or text + image).

| Part Type | OpenAI | opencode |
|-----------|--------|----------|
| `text` | Yes | Yes |
| `image` | Yes (`image_url`) | Yes (`source.base64`) |
| `reasoning` | No (separate `reasoning` field) | Yes (first-class part type) |
| `tool` | No (separate `tool_calls` field) | Yes (first-class part type with state) |
| `file` | No | Yes |
| `agent` | No | Yes (subagent invocation) |
| `subtask` | No | Yes |
| `tool-approval-request` | No | Yes |
| `tool-approval-response` | No | Yes |

### 7.6 Structured Output

Both support JSON schema output, but the API differs:

| Feature | OpenAI | opencode |
|---------|--------|----------|
| Request field | `response_format` | `format` |
| Schema format | JSON Schema | JSON Schema |
| Retry | No | `retryCount` (default 2) |
| Error handling | HTTP error | `StructuredOutputError` in response |

### 7.7 Context Management

| Feature | OpenAI | opencode |
|---------|--------|----------|
| Context compaction | No | Auto-compaction when context overflows |
| Compaction hooks | No | `experimental.session.compacting` plugin hook |
| Context pruning | No | Configurable (`compaction.prune`) |
| Token budget | Client manages | `compaction.reserved` buffer |

### 7.8 Permission System

| Feature | OpenAI | opencode |
|---------|--------|----------|
| Permission model | N/A | `allow` / `ask` / `deny` per tool, per agent |
| Interactive prompts | N/A | `POST /session/:id/permissions/:permissionID` |
| Wildcard matching | N/A | `Wildcard.match(toolName, rule.permission)` |
| Remember decision | N/A | `{ remember: true }` in permission response |

### 7.9 Plugin System

| Feature | OpenAI | opencode |
|---------|--------|----------|
| Plugin hooks | N/A | 20+ hook events |
| Plugin loading | N/A | npm packages or local files |
| Plugin events | N/A | `tool.execute.before/after`, `chat.message`, `shell.env`, `session.compacted`, `file.edited`, etc. |
| Custom tools via plugins | N/A | Yes, with Zod schema and `tool()` helper |

### 7.10 LSP and Formatter Integration

| Feature | OpenAI | opencode |
|---------|--------|----------|
| LSP servers | N/A | Auto-discovered, per-language |
| Code formatters | N/A | `prettier`, custom formatters |
| Symbol search | N/A | `GET /find/symbol` |
| Diagnostics | N/A | `lsp.client.diagnostics` event |

### 7.11 Other Extensions

| Feature | OpenAI | opencode |
|---------|--------|----------|
| Share links | N/A | `POST /session/:id/share` |
| mDNS discovery | N/A | `--mdns` flag |
| Desktop app | N/A | Tauri v2 (macOS, Windows, Linux) |
| IDE extensions | N/A | VS Code, Zed |
| GitHub Action | N/A | Built-in |
| Remote config | N/A | `.well-known/opencode` |
| Managed settings | N/A | MDM (macOS `.mobileconfig`), `/etc/opencode/` (Linux) |
| Image normalization | N/A | Auto-resize, max base64 bytes |
| Provider blacklist/whitelist | N/A | Per-provider model filtering |
| Model variants | N/A | Built-in (high/low/medium) + custom |
| OpenTelemetry | N/A | `experimental.openTelemetry` |
| Native LLM runtime | N/A | `experimentalNativeLlm` flag (bypasses AI SDK) |

---

## 8. Integration Summary

### What We Build

1. **APISIX routes**: one per upstream LLM provider, each with the full
   plugin stack (key-auth, ai-rate-limiting, prometheus, http-logger,
   proxy-buffering, proxy-rewrite, redact).
2. **opencode config**: custom providers with `baseURL` pointing to
   APISIX routes. `npm` field selects the AI SDK factory (native or
   OpenAI-compatible). `apiKey` is the real upstream key.
3. **Telemetry pipeline**: APISIX `http-logger` to Vector to ClickHouse.
   Prometheus scrapes APISIX metrics endpoint.
4. **PII redaction**: custom Lua `redact` plugin on every LLM route.
5. **Rate limiting**: `ai-rate-limiting` plugin, per-model RPM.
6. **SSE pass-through**: `proxy-buffering` plugin with `disable: true`
   on every LLM route.

### What We Do NOT Build

- No format conversion in APISIX (opencode's AI SDK handles all of it).
- No OAuth flows in APISIX (opencode handles Copilot/GitLab/ChatGPT
  OAuth natively).
- No AWS SigV4 in APISIX (opencode's `@ai-sdk/amazon-bedrock` handles
  it, APISIX just relays the signed request).
- No Google ADC in APISIX (opencode's `@ai-sdk/google-vertex` handles
  it, APISIX just relays).
- No tool execution in APISIX (opencode's agent loop handles it).
- No session management in APISIX (opencode's server handles it).

### Data Flow

```
1. User sends prompt to opencode TUI/SDK/CLI
2. opencode creates session, runs agent prompt loop
3. Agent loop calls AI SDK streamText()
4. AI SDK factory serializes ModelMessage[] to provider-native JSON
5. AI SDK fetch() sends HTTP to APISIX (baseURL in opencode config)
6. APISIX key-auth validates gateway key
7. APISIX ai-rate-limiting checks model RPM
8. APISIX redact scans request body for PII
9. APISIX proxy-rewrite strips provider prefix from URI
10. APISIX relays to upstream LLM provider
11. Upstream responds (JSON or SSE stream)
12. APISIX proxy-buffering passes SSE through unbuffered
13. APISIX redact scans response for PII (re-hydrate tokens)
14. APISIX prometheus records metrics
15. APISIX http-logger sends log to Vector -> ClickHouse
16. opencode AI SDK parses response/SSE
17. opencode SessionProcessor builds message parts
18. opencode publishes events to /event SSE bus
19. Client receives response via /session/:id/message (sync) or /event (stream)
```
