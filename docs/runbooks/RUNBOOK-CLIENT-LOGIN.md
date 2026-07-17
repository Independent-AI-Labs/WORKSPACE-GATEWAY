# RUNBOOK-CLIENT-LOGIN: OpenCode Provider Login

**Date:** 2026-07-17
**Status:** Active
**Type:** Runbook

---

## Purpose

End-user procedure for installing a gateway-managed provider into a local
OpenCode configuration using
[`res/scripts/opencode-provider-login.sh`](../../res/scripts/opencode-provider-login.sh).
The script fetches a ready-to-use provider block from the gateway's
provider-sync service, performs any required authentication (OAuth device flow
or API key prompt), and writes the provider into the user's OpenCode config and
auth files. Background: [SPEC-PROVIDER-SYNC](../specifications/SPEC-PROVIDER-SYNC.md),
[SPEC-PROVIDER-KIMI](../specifications/SPEC-PROVIDER-KIMI.md) §8.

## Prerequisites

- `curl` and `jq` installed (script checks both).
- Gateway reachable (default `http://localhost:9080`) with the
  `gateway-provider-sync` route serving `/gateway/providers*`.
- A provider ID from `conf/providers/*.yaml`, e.g. `workspace-gw-kimi-oauth`,
  `workspace-gw-kimi-own`, `workspace-gw-kimi-private`, `workspace-gw-llamafile`,
  `workspace-gw-own`, `workspace-gw-private`.
- For OAuth providers: a browser (or copy/paste of the verification URL).
- For `api_key`/`virtual_key` providers: a key ready to paste (issue one via
  [RUNBOOK-KEYS](RUNBOOK-KEYS.md)).

## Procedures

### 1. Discover available providers

```bash
curl -s http://localhost:9080/gateway/providers | jq .
```

### 2. Run the login script

```bash
bash res/scripts/opencode-provider-login.sh --provider-id workspace-gw-kimi-oauth
```

| Flag | Default | Meaning |
|------|---------|---------|
| `--provider-id ID` | (required) | Provider ID |
| `--gateway URL` | `http://localhost:9080` | Gateway base URL (must be http/https) |
| `--session ID` | `opencode-<timestamp>` | OAuth session label |
| `--config-file PATH` | `~/.config/opencode/opencode.jsonc` (or `.json`) | OpenCode config path |
| `--auth-file PATH` | `~/.local/share/opencode/auth.json` | OpenCode auth path |
| `--user-agent UA` | `Kimi CLI (Linux 6.17.0-35-generic x64)` | User-Agent on all requests |
| `--no-browser` | off | Do not auto-open the browser for OAuth |
| `--no-prompt` | off | Fail instead of prompting for API keys |
| `--device-timeout SEC` | `900` | OAuth polling timeout (positive integer) |
| `--help` | | Show usage |

### 3. What the script does

1. Fetches `GET <gateway>/gateway/providers/<id>/opencode` and reads
   `.provider`, `.auth_type`, and `.auth_route`.
2. Authenticates according to `auth_type`:
   - `oauth`: starts the device flow via
     `POST <gateway><auth_route>/device?session=<session>`, prints the user code
     and verification URL, opens the browser (unless `--no-browser`), and polls
     `POST <gateway><auth_route>/device/poll` until an `access_token` is
     returned. Honors `authorization_pending` (keep waiting), `slow_down`
     (adds 5s to the interval), `expired_token`, and `access_denied`.
   - `api_key` / `virtual_key`: prompts for the key interactively (fails under
     `--no-prompt`).
   - `none` / `passthrough`: no credential needed.
3. Merges `.provider` into `provider.<id>` of the OpenCode config file
   (JSONC-aware: comments are stripped for parsing, other providers are
   preserved).
4. Writes the credential into `auth.json` as `{"<id>": {"type": "api", "key":
   "<token>"}}` and chmods it `600`.

### 4. Use the provider

```bash
opencode -m workspace-gw-kimi-oauth/<model-id>
```

Or start the OpenCode TUI and select the provider by name.

## Verification

1. `jq '.provider["workspace-gw-kimi-oauth"].name' ~/.config/opencode/opencode.jsonc`
   returns the provider name.
2. `jq 'has("workspace-gw-kimi-oauth")' ~/.local/share/opencode/auth.json`
   returns `true` (for oauth/api_key providers).
3. `opencode -m <provider-id>/<model-id>` completes a chat round-trip.
4. `stat -c %a ~/.local/share/opencode/auth.json` shows `600`.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `gateway returned an invalid provider response` | Bad provider ID or gateway down | List providers (step 1); check stack health |
| `unsupported auth_type` | Gateway returned an unknown auth_type | Update the script or use a supported provider |
| `device code expired` / `expired_token` | User took too long (>900s default) | Re-run; raise `--device-timeout` |
| `authorization denied` | User rejected the OAuth prompt | Re-run and approve |
| Browser does not open | Headless environment | Use `--no-browser` and open the printed verification URL manually |
| `provider requires an API key but --no-prompt is set` | Non-interactive run | Drop `--no-prompt`, or pre-provision `auth.json` |
| `config file is not valid JSON/JSONC` | Corrupt existing config | Fix or move `~/.config/opencode/opencode.jsonc` aside and re-run |
| Chat returns 401 after login | Stale/expired credential | Re-run the script; for virtual keys check status via [RUNBOOK-KEYS](RUNBOOK-KEYS.md) |
