# OPENCODE-SERVER-API: opencode Server API Reference

**Date:** 2026-07-17
**Status:** Active
**Type:** Reference

> Third-party reference material. This document describes the **upstream
> opencode CLI's own HTTP server API** (`opencode serve`, default `:4096`,
> OpenAPI 3.1 spec at `GET /doc`), NOT the WORKSPACE-GATEWAY codebase and NOT
> the OpenCode Go upstream API. Extracted from
> Extracted from the legacy OPENCODE-INTEGRATION doc §7 (v1.17.13 server docs).

---

## 1. Authentication

HTTP Basic Auth. Enabled when `OPENCODE_SERVER_PASSWORD` is set.

| Header | Format |
|--------|--------|
| `Authorization` | `Basic base64(username:password)` |
| Query `?auth_token=` | `base64(username:password)` |

Username defaults to `opencode`. Override with `OPENCODE_SERVER_USERNAME`.
No auth when password is unset (default).

## 2. Global

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/global/health` | Server health and version |
| `GET` | `/global/event` | Global events (SSE stream) |

## 3. Project

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/project` | List all projects |
| `GET` | `/project/current` | Get the current project |

## 4. Path and VCS

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/path` | Get the current path |
| `GET` | `/vcs` | Get VCS info for current project |

## 5. Instance

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/instance/dispose` | Dispose the current instance |

## 6. Config

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/config` | Get config info |
| `PATCH` | `/config` | Update config |
| `GET` | `/config/providers` | List providers and default models |

## 7. Provider

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/provider` | List all providers |
| `GET` | `/provider/auth` | Get provider auth methods |
| `POST` | `/provider/{id}/oauth/authorize` | Authorize provider via OAuth |
| `POST` | `/provider/{id}/oauth/callback` | Handle OAuth callback |

## 8. Sessions

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

## 9. Messages (the core prompt endpoint)

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/session/:id/message` | List messages in session |
| `POST` | `/session/:id/message` | Send a message, wait for response |
| `GET` | `/session/:id/message/:messageID` | Get message details |
| `POST` | `/session/:id/prompt_async` | Send a message asynchronously |
| `POST` | `/session/:id/command` | Execute a slash command |
| `POST` | `/session/:id/shell` | Run a shell command |

### 9.1 POST /session/:id/message Request Body

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
    "schema": { "type": "object", "properties": { } },
    "retryCount": 2
  }
}
```

### 9.2 POST /session/:id/message Response

```json
{
  "info": {
    "id": "msg_abc123",
    "sessionID": "sess_xyz789",
    "role": "assistant",
    "time": 1720195200,
    "model": { "providerID": "workspace-gw-private", "modelID": "minimax-m3" },
    "cost": { "input": 0.003, "output": 0.015, "total": 0.018 },
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

## 10. Commands

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/command` | List all commands |

## 11. Files

| Method | Path | Description | Query |
|--------|------|-------------|-------|
| `GET` | `/find` | Search for text in files | `?pattern=` |
| `GET` | `/find/file` | Find files/dirs by name | `?query=&type=&directory=&limit=` |
| `GET` | `/find/symbol` | Find workspace symbols | `?query=` |
| `GET` | `/file` | List files and directories | `?path=` |
| `GET` | `/file/content` | Read a file | `?path=` |
| `GET` | `/file/status` | Get status for tracked files | |

## 12. Tools (Experimental)

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/experimental/tool/ids` | List all tool IDs |
| `GET` | `/experimental/tool` | List tools with JSON schemas |

## 13. LSP, Formatters and MCP

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/lsp` | Get LSP server status |
| `GET` | `/formatter` | Get formatter status |
| `GET` | `/mcp` | Get MCP server status |
| `POST` | `/mcp` | Add MCP server dynamically |

## 14. Agents

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/agent` | List all available agents |

## 15. Logging

| Method | Path | Description | Body |
|--------|------|-------------|------|
| `POST` | `/log` | Write log entry | `{ service, level, message, extra? }` |

## 16. TUI Control

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

## 17. Auth

| Method | Path | Description | Body |
|--------|------|-------------|------|
| `PUT` | `/auth/:id` | Set auth credentials for a provider | Provider-specific |

## 18. Events (SSE)

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/event` | Server-sent events stream |

First event is `server.connected`, then bus events. 10-second heartbeat
(`server.heartbeat`). Response headers: `Cache-Control: no-cache,
no-transform`, `X-Accel-Buffering: no`, `Content-Type: text/event-stream`.

Events include: `session.updated`, `session.created`, `session.deleted`,
`session.idle`, `session.error`, `message.updated`, `message.removed`,
`message.part.updated`, `message.part.removed`, `tool.execute.before`,
`tool.execute.after`, `permission.asked`, `permission.replied`, `file.edited`,
`lsp.updated`, `server.connected`, `server.heartbeat`,
`server.instance.disposed`.

## 19. Docs

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/doc` | OpenAPI 3.1 specification |
