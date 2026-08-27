# OAuth/Login Surface Audit

**Date:** 2026-08-06
**Status:** Open
**Scope:** Kimi OAuth, OpenAI OAuth, provider-sync, the local provider login
client, token custody, routes, tests, and documentation.

## Executive Summary

The repository has two gateway-managed OAuth implementations and one generic
local provider installer. OpenAI now has a verified browser
authorization-code/PKCE contract and a gateway-owned OpenCode plugin path; Kimi
remains device-code-only because no upstream browser contract was found.

The names and boundaries are unclear:

- `res/scripts/opencode-provider-login.sh` is a gateway provider bootstrapper,
  not an OpenAI/Kimi OAuth implementation.
- `kimi-auth.lua` and `openai-auth.lua` own the provider-specific OAuth protocol,
  session lookup, refresh, and upstream header injection.
- Provider-sync publishes OAuth metadata, but method selection and method routes
  are not consistently honored.
- The gateway-owned OpenCode plugin is the intended OAuth entry point; the shell
  installer remains a legacy device/API-key installer.

The external plugin is a gateway-owned TypeScript module. Its dependency must
come from the published `@opencode-ai/plugin` package through Bun. The gateway
must not copy OpenCode's plugin module or create a `workspace:*` dependency on
the sibling OpenCode checkout.

Dependency setup is also subject to the workspace convention: learn the
hermetic boot, version-pinning, lockfile, CI, and generated-hook patterns from
`WORKSPACE-CI` and `WORKSPACE-VM`, then apply them to Bun. The requirement is
not to replace Bun with npm; it is to avoid an ad hoc Bun installation and an
untracked CI dependency. The gateway retains its existing Lua/shell CI language
profile and runs Bun checks through explicit Make targets.

An uncommitted change made during this audit added a browser branch to the
generic installer. That branch called gateway endpoints from an inline Python
callback server. It has been removed; browser OAuth now belongs in the
gateway-owned OpenCode plugin.

Upstream contract check:

- OpenAI's OpenCode integration documents an authorization-code + PKCE flow with
  `https://auth.openai.com/oauth/authorize`,
  `http://localhost:1455/auth/callback`, and
  `https://auth.openai.com/oauth/token`.
- Kimi's available official integration material describes RFC 8628 device
  authorization at `auth.kimi.com`; no regular browser authorization-code flow
  has been established. Kimi browser support must not be invented by copying the
  OpenAI contract.

## Evidence Collected

### OpenAI

Official OpenCode source was fetched from:

`https://raw.githubusercontent.com/anomalyco/opencode/dev/packages/opencode/src/plugin/openai/codex.ts`

It confirms the client ID, issuer, PKCE S256 parameters, scopes, OpenAI-specific
authorization parameters, redirect URI `http://localhost:1455/auth/callback`,
`/oauth/authorize`, and `/oauth/token` exchange used by the browser method. The
same contract is present in:

`https://raw.githubusercontent.com/anomalyco/opencode/dev/packages/core/src/plugin/provider/openai.ts`

Safe live probes from this environment produced:

| Probe | Result | Meaning |
|---|---:|---|
| OpenAI authorize URL with intentionally invalid PKCE | HTTP 403 | Upstream edge is reachable and rejected the invalid probe |
| OpenAI token exchange with dummy code/verifier | HTTP 401 | Token endpoint is reachable and rejected invalid credentials |

These probes used no account or credential and did not complete a login.

### Kimi

Official Kimi source and design documentation were fetched from:

- `https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/src/kimi_cli/auth/oauth.py`
- `https://raw.githubusercontent.com/MoonshotAI/kimi-cli/main/klips/klip-14-kimi-code-oauth-login.md`

Both document only RFC 8628 device authorization:

- `POST https://auth.kimi.com/api/oauth/device_authorization`
- `POST https://auth.kimi.com/api/oauth/token`
- refresh through the same token endpoint
- browser opening only for the device verification URL

Safe live probes from this environment produced:

| Probe | Result | Meaning |
|---|---:|---|
| Kimi device authorization with the public client ID | HTTP 200 | Device contract is live and returned the documented response shape |
| Kimi guessed `/oauth/authorize` URL | HTTP 404 | No regular browser endpoint was found at that path |

The device probe generated a temporary device record. Its response was not
stored in the repository or this audit, and no follow-up poll was performed.

**Conclusion:** OpenAI browser PKCE has verified upstream evidence. Kimi browser
PKCE does not. Kimi remains device-flow-only until Moonshot publishes a valid
authorization-code contract or one is supplied by the owner.

## Current Call Graph

### Local installer

`res/scripts/opencode-provider-login.sh`:

1. Fetches `GET /gateway/providers/<id>/opencode`.
2. Reads the provider block and `auth_type`.
3. Runs device OAuth, API-key prompting, or no-auth handling.
4. Merges the provider block into the local OpenCode config.
5. Writes an API credential to OpenCode `auth.json`.

It is therefore a **provider installation and credential persistence client**.
It is not a Kimi login script or an OpenAI login script.

### Kimi

`kimi-auth.lua` handles:

- `POST /kimi/auth/device`
- `POST /kimi/auth/device/poll`
- bearer session lookup
- refresh
- upstream authorization and gateway metadata headers

`kimi_device.lua` calls Kimi's device authorization and token endpoints.

### OpenAI

`openai-auth.lua` handles:

- `POST /openai/auth/device`
- `POST /openai/auth/device/poll`
- bearer session lookup
- refresh
- account-id, originator, session-id, and gateway metadata headers

`openai_device.lua` calls OpenAI's device endpoints and exchanges the resulting
authorization code with `/oauth/token`.

## Findings

### OAUTH-001: Browser OAuth was not implemented

**Severity:** Critical
**Status:** Resolved for OpenAI; Kimi remains device-only

At audit time neither auth plugin handled browser authorization routes:

- `plugins/custom/kimi-auth.lua:224-232`
- `plugins/custom/openai-auth.lua:107-110`

Both only handle device start and device polling. The requested regular browser
flow therefore has no gateway implementation, no state store, no PKCE handling,
and no browser callback exchange. OpenAI now has browser start/callback routes
and the gateway-owned OpenCode plugin consumes them. Kimi remains device-only.

### OAUTH-002: Provider definitions must advertise supported methods

**Severity:** Critical
**Status:** Resolved for OpenAI; Kimi intentionally device-only

The provider YAML files are the source of provider method metadata:

- `conf/providers/workspace-gw-kimi-device-oauth.yaml:9-15`
- `conf/providers/workspace-gw-openai-device-oauth.yaml:9-15`

OpenAI now declares both `chatgpt-headless` and `chatgpt-browser`; Kimi declares
only its verified device method. Provider-sync cannot expose a method absent from
these definitions.

### OAUTH-003: Unsupported browser client change

**Severity:** Critical
**Status:** Removed

The uncommitted change to `res/scripts/opencode-provider-login.sh` adds calls to:

- `<auth_route>/browser`
- `<auth_route>/browser/callback`

No server implements either route. The change is a client-side facade for an
unimplemented protocol and was removed. The supported replacement is
`res/opencode-plugin/workspace-gateway-auth.ts`, loaded through OpenCode's
standard plugin configuration.

### OAUTH-004: Method-specific routes are ignored

**Severity:** High
**Status:** Resolved

Provider methods contain their own routes, but
`plugins/custom/provider-sync.lua:97-107` reconstructs one generic route from
`provider.route .. "/auth"`. A provider with distinct device and browser routes
can be described one way and executed another way.

### OAUTH-005: Method metadata is exposed without method dispatch

**Severity:** High
**Status:** Resolved

`provider-sync.lua:99-121` returns `auth_methods`, but the installer currently
uses a generic auth route and hard-coded device endpoint suffixes. A flow method
must be selected explicitly and its route, identifier, and protocol parameters
must be used together.

### OAUTH-006: OpenAI method identifier contradicts requirements

**Severity:** Medium
**Status:** Open

The requirement calls for `chatgpt-headless`, while
`conf/providers/workspace-gw-openai-device-oauth.yaml:13` uses
`openai-device-oauth`. The identifier must have one canonical owner and value.

### OAUTH-007: Kimi transport disables TLS verification

**Severity:** Critical
**Status:** Open

`plugins/custom/kimi_device.lua:25-34` sets `ssl_verify = false` for OAuth
requests. This contradicts the HTTPS security requirements and exposes OAuth
credentials to man-in-the-middle attacks.

### OAUTH-008: OpenBao transport uses plaintext by default

**Severity:** High
**Status:** Open

Both auth plugins default OpenBao to `http://openbao:8200`:

- `plugins/custom/kimi-auth.lua:32-35`
- `plugins/custom/openai-auth.lua:13-16`

Token custody should use an explicit secure transport policy rather than silently
selecting plaintext.

### OAUTH-009: OpenAI expiry parsing is unsafe

**Severity:** High
**Status:** Open

`plugins/custom/openai-auth.lua:91-95` compares against
`tonumber(pending.expires_at)` without checking conversion. Malformed storage can
cause an error instead of a controlled invalid-session response.

### OAUTH-010: OpenAI token response validation is incomplete

**Severity:** High
**Status:** Open

`plugins/custom/openai_device.lua:95-104` and `:119-127` silently default missing
expiry values. `openai-auth.lua:59-68` stores a possibly missing refresh token.
Malformed upstream responses should fail closed with a protocol error.

### OAUTH-011: Kimi refresh state can race or become stale

**Severity:** High
**Status:** Open

`plugins/custom/kimi-auth.lua:197-214` refreshes without a lock. It continues
using a refreshed token even when persistence fails. Concurrent requests can
rotate refresh tokens and leave the stored session unusable.

### OAUTH-012: Account claim decoding is inconsistent

**Severity:** Medium
**Status:** Open

`plugins/custom/openai-auth.lua:46-53` does not add JWT Base64 padding before
decoding. `kimi_jwt.lua:17-25` handles JWT decoding differently. Shared JWT
decoding behavior should live in one helper.

### OAUTH-013: Token-storage error handling can leak response bodies

**Severity:** High
**Status:** Open

`plugins/custom/kimi_tokens.lua:41-43` incorporates the full OpenBao response
body into errors. Error bodies must be sanitized before logging or returning.

### OAUTH-014: Device records have no explicit TTL cleanup

**Severity:** Medium
**Status:** Open

Records are deleted on normal success or observed expiry, but abandoned records
are not given a storage TTL in `kimi_tokens.lua:56-83`. OpenBao cleanup policy is
not explicit in the code or deployment contract.

### OAUTH-015: Auth plugins duplicate session and refresh logic

**Severity:** Medium
**Status:** Open

Kimi and OpenAI separately implement session-record construction, refresh
handling, bearer lookup, and gateway metadata. This has already produced
behavioral differences in expiry validation, claim parsing, and error handling.

### OAUTH-016: Routes are duplicated across generated/configured files

**Severity:** Medium
**Status:** Open

Kimi/OpenAI route definitions exist in both `conf/apisix.yaml` and
`conf/apisix.yaml.j2`, in addition to provider YAML route metadata. Manual drift
is likely unless one source is made authoritative and generated output is tested
against it.

### OAUTH-017: Runtime route ordering is insufficiently tested

**Severity:** High
**Status:** Open

The routes rely on `kimi-auth`, `key-meta`, and rate-limit ordering. Config tests
verify YAML shape but not actual APISIX execution or whether the generated key is
available before rate limiting.

### OAUTH-018: OpenAI path rewriting has a narrow contract

**Severity:** Medium
**Status:** Open

`conf/apisix.yaml:138-140` rewrites matching OpenAI paths to one Codex responses
endpoint. This is intentional for Codex but is not clearly distinguished from a
general OpenAI-compatible provider in the generated provider metadata.

### OAUTH-019: OAuth tests are incomplete

**Severity:** High
**Status:** Open

Existing coverage focuses on device flow:

- `tests/scripts/test_opencode_provider_login.sh`
- `tests/integration/test_provider_sync_client.sh`
- `tests/lua/test_kimi_jwt.lua`

Missing coverage includes callback replay, refresh rotation, OpenBao failures,
malformed records, OpenAI end-to-end OAuth, and plugin order. The gateway plugin
now has focused method-registration, device, browser-state, pending,
slow-down, and terminal-error tests; full upstream OAuth coverage remains
tracked in `docs/TODO.md`.

### OAUTH-020: Fixtures do not match production identifiers

**Severity:** Medium
**Status:** Open

`tests/lua/test_provider_sync.lua:323-330` uses `kimi-headless`, while production
uses `kimi-device-oauth`. Fixture success does not prove production metadata
compatibility.

### OAUTH-021: Documentation contradicts implementation

**Severity:** Medium
**Status:** Open

Examples:

- OpenAI docs say `originator` and `session-id` are omitted, but
  `openai-auth.lua:128-134` injects them.
- The runbook says OAuth requires a browser while the implemented flow is device
  authorization.
- Requirements mark implementation complete while documenting TLS, locking,
  and opaque-code gaps.
- Static example configs duplicate model catalogs generated by provider-sync.

The authoritative OAuth requirements, specification, runbook, plugin README,
and execution checklist are being synchronized in this change. Remaining
implementation gaps must stay explicitly marked pending until their tests pass.

### OAUTH-022: Published Bun plugin dependency is not yet packaged

**Severity:** High
**Status:** Resolved, landing pending

`res/opencode-plugin/workspace-gateway-auth.ts` imports the public
`@opencode-ai/plugin` types and its tests use `bun:test`. The gateway now owns
a Bun manifest and lockfile for the published dependency.
`bun install --frozen-lockfile`, Bun typechecking, and focused plugin tests pass
without a path or workspace dependency on `projects/opencode`. The change set
is verified locally; the commit has not yet landed (see `docs/TODO.md` P3.5).

### OAUTH-023: Pending device poll must remain non-terminal

**Severity:** High
**Status:** Resolved, landing pending

The plugin request helper now explicitly accepts HTTP 202 for device polling.
The Bun suite covers `authorization_pending`, `slow_down`, and a terminal
device error; pending states continue polling instead of becoming
`request_failed`. The change set is verified locally; the commit has not yet
landed (see `docs/TODO.md` P3.5).

## Required Target Design

1. Define provider-specific browser contracts for Kimi and OpenAI before editing
   the generic installer. OpenAI's contract is now verified; Kimi remains
   device-only.
2. Generate PKCE verifier/challenge and state in the local client or gateway,
   with one clear owner for validation.
3. Add provider-specific authorize-start and callback/token-exchange handling to
   the corresponding auth plugin/helper. OpenAI gateway routes now provide this
   contract, and `res/opencode-plugin/workspace-gateway-auth.ts` consumes it.
4. Persist pending browser sessions separately from device sessions, with expiry,
   one-time state use, and no client secret storage.
5. Represent device and browser methods explicitly in provider YAML.
6. Make provider-sync return the selected method route without reconstructing it.
7. Make the client dispatch by method object, not by global `auth_type` heuristics.
8. Share safe token/session validation and storage helpers where behavior is
   identical; keep upstream protocol differences in provider adapters.
9. Add deterministic mock tests for both providers and both flows.
10. Update requirements, specifications, runbooks, examples, and architecture
    diagrams only after behavior and tests agree.

## Immediate Remediation Order

1. Remove the unsupported browser branch from `opencode-provider-login.sh`.
2. Package the gateway plugin with the published Bun dependency and frozen lockfile.
3. Load and test the gateway-owned OpenCode auth plugin, including pending polls.
4. Correct the provider/method contract and canonical identifiers.
5. Harden TLS, storage errors, expiry validation, and refresh locking.
6. Add provider-specific browser-flow tests.
7. Establish and verify Kimi's actual browser OAuth contract before any browser
   implementation; do not infer it from OpenAI.
8. Synchronize documentation and generated/provider fixtures.
