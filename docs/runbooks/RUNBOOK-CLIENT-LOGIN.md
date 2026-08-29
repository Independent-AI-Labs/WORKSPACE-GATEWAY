# RUNBOOK-CLIENT-LOGIN: OpenCode Provider Login

**Date:** 2026-08-06
**Status:** Active
**Type:** Runbook

---

## Purpose

End-user procedure for installing a gateway-managed provider into a local
OpenCode configuration using
[`res/scripts/opencode-provider-login.sh`](../../res/scripts/opencode-provider-login.sh).
The script fetches a ready-to-use provider block from the gateway's
provider-sync service, performs legacy headless device/API-key setup, and writes
the provider into the user's OpenCode config and auth files. Browser/device
OAuth through OpenCode's native auth UI uses the gateway-owned plugin described
below. Background: [SPEC-PROVIDER-SYNC](../specifications/SPEC-PROVIDER-SYNC.md),
[SPEC-PROVIDER-KIMI](../specifications/SPEC-PROVIDER-KIMI.md) §8.

## Prerequisites

- `curl` and `jq` installed (script checks both).
- Gateway reachable (default `http://localhost:9080`) with the
  `gateway-provider-sync` route serving `/gateway/providers*`.
- A provider ID from `conf/providers/*.yaml`, e.g. `workspace-gw-kimi-device-oauth`,
  `workspace-gw-kimi-api-key`, `workspace-gw-kimi-virtual-key`,
  `workspace-gw-llamafile-no-auth`.
- For OAuth providers: a browser (or copy/paste of the verification URL).
- For preferred OpenCode OAuth: Bun and the gateway-owned plugin dependencies
  installed from the public registry; see [Plugin setup](#plugin-setup).
- For `api_key`/`virtual_key` providers: a key ready to paste (issue one via
  [RUNBOOK-KEYS](RUNBOOK-KEYS.md)).

## Procedures

### 1. Discover available providers

```bash
curl -s http://localhost:9080/gateway/providers | jq .
```

### 2. Run the login script

Install ALL providers at once (config-only; keys/OAuth deferred by default):

```bash
make setup-providers
# or, prompting for keys and running OAuth device flows:
make setup-providers REQUIRE_AUTH=1
```

Install or re-authenticate a single provider:

```bash
bash res/scripts/opencode-provider-login.sh --provider-id workspace-gw-kimi-device-oauth
# with key prompt / OAuth (otherwise config-only):
bash res/scripts/opencode-provider-login.sh --provider-id workspace-gw-zai-api-key --require-auth
```

### 2a. Preferred OpenCode OAuth setup

#### Plugin setup

The preferred flow uses the gateway-owned external plugin. The plugin is not
vendored into OpenCode and must not import a sibling checkout path. From the
gateway repository, install its pinned Bun dependencies after the gateway Bun
package setup in [TODO.md](../TODO.md) is complete, then use the generated
example configuration:

```bash
cd "$WORKSPACE_GATEWAY_ROOT"
make plugin-install BUN="$BUN"
make plugin-type-check BUN="$BUN"
make plugin-test BUN="$BUN"
```

Bun must be supplied through the hermetic workspace bootstrap convention, not
from an unpinned system installation. The dependency declaration, runtime
version, lockfile, Make targets, and generated hooks must follow the patterns
used by `WORKSPACE-CI` and `WORKSPACE-VM`.

The dependency is the published `@opencode-ai/plugin` package. Do not copy
`projects/opencode/packages/plugin`, add a `workspace:*` dependency, or rewrite
the upstream `Hooks` types. The gateway plugin owns only the gateway adapter
and its tests.

Add the gateway-owned plugin to `opencode.json` using the example files in
`res/`:

- OpenAI registers both `ChatGPT Pro/Plus (browser)` and
  `ChatGPT Pro/Plus (headless)`.
- Kimi registers `Kimi Code (device authorization)`.

Then run:

```bash
opencode auth login -p workspace-gw-openai-device-oauth
```

Select either OpenAI method. The plugin starts the flow through the gateway;
the gateway exchanges upstream tokens and stores the session. Do not add an
inline Python/Perl/Node callback server to the shell installer. Kimi exposes
only device authorization because no verified Kimi browser authorization-code
contract is documented.

| Flag | Default | Meaning |
|------|---------|---------|
| `--provider-id ID` | (required unless `--all`) | Provider ID |
| `--all` | off | Install every provider from `/gateway/providers` (config-only unless `--require-auth`) |
| `--require-auth` | off | Prompt for API keys / run OAuth instead of skipping auth |
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
    - `oauth` in the legacy script: starts the brokered headless device flow via
     `POST <gateway><auth_route>/device?session=<session>`, prints the user code
     and verification URL, opens the browser (unless `--no-browser`), and polls
      `POST <gateway><auth_route>/device/poll` with the opaque gateway device code until an `access_token` is
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

The preferred plugin path does not use the shell installer to host a callback
server. OpenAI browser OAuth uses OpenCode's loopback callback on port 1455;
the plugin validates the returned state before sending the code to the gateway.

### 4. Use the provider

```bash
opencode -m workspace-gw-kimi-device-oauth/<model-id>
```

Or start the OpenCode TUI and select the provider by name.

## Verification

1. `jq '.provider["workspace-gw-kimi-device-oauth"].name' ~/.config/opencode/opencode.jsonc`
   returns the provider name.
2. `jq 'has("workspace-gw-kimi-device-oauth")' ~/.local/share/opencode/auth.json`
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
| `bun install --frozen-lockfile` fails | Gateway Bun manifest and lockfile are out of sync | Run the documented dependency update procedure and commit both files together |
| Plugin cannot resolve `@opencode-ai/plugin` | Dependency was installed from an OpenCode workspace or not installed | Use the published package from the gateway repository; do not use `workspace:*` or a sibling path |
| Device flow fails after `authorization_pending` | A pending HTTP 202 was treated as a terminal error | Check the plugin polling test and preserve 202 as an intermediate response |
| `provider requires an API key but --no-prompt is set` | Non-interactive run | Drop `--no-prompt`, or pre-provision `auth.json` |
| `config file is not valid JSON/JSONC` | Corrupt existing config | Fix or move `~/.config/opencode/opencode.jsonc` aside and re-run |
| Chat returns 401 after login | Stale/expired credential | Re-run the script; for virtual keys check status via [RUNBOOK-KEYS](RUNBOOK-KEYS.md) |
