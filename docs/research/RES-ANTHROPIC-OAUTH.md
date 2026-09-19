# RES-ANTHROPIC-OAUTH: Proxying Anthropic Auth Through the Gateway

**Date:** 2026-09-19
**Status:** Research complete
**Related:** [REQ-PROVIDER-ANTHROPIC](../requirements/REQ-PROVIDER-ANTHROPIC.md), [SPEC-PROVIDER-ANTHROPIC](../specifications/SPEC-PROVIDER-ANTHROPIC.md)

> Answers one question: can WORKSPACE-GATEWAY proxy Anthropic end to end,
> including all authentication, while downstream clients (claude, opencode)
> keep using their own standard credential mechanisms with zero user
> configuration? Short answer: the data plane yes, fully; the login and
> refresh plane no supported path exists (the CLI hardcodes it); an upstream
> device flow does not exist at all. Sources: Claude Code published source
> (`src/constants/oauth.ts`, `src/utils/auth.ts`, `src/services/oauth/client.ts`,
> `services/api/client.ts`), the official env-vars and authentication docs,
> and community reimplementations of the same flow.

## 1. How Claude Code authenticates

Credential sources, in the order the client itself checks them
(`src/utils/auth.ts`, `getAuthTokenSource`):

1. `ANTHROPIC_AUTH_TOKEN` env (sent as `Authorization: Bearer`)
2. `CLAUDE_CODE_OAUTH_TOKEN` env (long-lived token from `claude setup-token`)
3. `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR` / CCR file path
4. `apiKeyHelper` setting
5. `/login`-managed OAuth tokens (keychain / `~/.claude/.credentials.json`)
6. `ANTHROPIC_API_KEY` env / `/login`-managed console key (sent as `x-api-key`)

Two facts drive everything below:

- When none of items 1-4 are set, a `/login` subscriber's OAuth access
  token is attached as `Authorization: Bearer` on every API request, and
  the request goes to whatever `ANTHROPIC_BASE_URL` points at
  (`services/api/client.ts`: `authToken` from the credential store,
  `baseURL` from the SDK env).
- Setting any external key/token env DISABLES the OAuth path entirely
  (`isAnthropicAuthEnabled` returns false), which also drops the
  OAuth-specific beta headers. A wrapper must not set them.

On the wire, OAuth-authenticated calls carry `anthropic-beta:
oauth-2025-04-20` (plus feature betas) and hit the beta messages path
(`/v1/messages?beta=true`); the claude-code-scoped token is rejected
without them ("credential only authorized for Claude Code").

## 2. The OAuth protocol (verified constants and quirks)

From `PROD_OAUTH_CONFIG` in `src/constants/oauth.ts` (plus the older
v2.0.69 deobfuscation showing the same values pre-migration):

| Constant | Value |
|----------|-------|
| CLIENT_ID | `9d1c250a-e61b-44d9-88ed-5944d1962f5e` (public Claude Code client) |
| CLAUDE_AI_AUTHORIZE_URL | `https://claude.com/cai/oauth/authorize` (307 hops to claude.ai; older builds: `https://claude.ai/oauth/authorize`) |
| CONSOLE_AUTHORIZE_URL | `https://platform.claude.com/oauth/authorize` (older: console.anthropic.com) |
| TOKEN_URL | `https://platform.claude.com/v1/oauth/token` (older: console.anthropic.com) |
| MANUAL_REDIRECT_URL | `https://platform.claude.com/oauth/code/callback` (page displays `CODE#STATE`) |
| API_KEY_URL | `https://api.anthropic.com/api/oauth/claude_cli/create_api_key` |
| loopback callback | `http://localhost:54545/callback` |

Protocol quirks that any reimplementation must copy exactly:

- PKCE S256 with a 43-char base64url verifier; the `state` parameter MUST
  equal the `code_verifier` (non-standard, verified across four
  independent implementations).
- The authorize URL carries `code=true` (upsell page variant).
- The manual callback returns `CODE#STATE`; the client splits on `#` and
  the state half must equal the verifier.
- Token exchange AND refresh are `Content-Type: application/json` bodies
  (not form-encoded); exchange includes `state`; refresh may expand scopes.
- Scopes: `user:inference user:profile` minimum; current client also
  requests `user:sessions:claude_code user:mcp_servers user:file_upload`
  and `org:create_api_key` on the browser leg.
- Access tokens are short-lived (hours); the client refreshes on its own
  schedule; refresh responses may omit a new refresh token (keep old).
- Provisioning env pair: `CLAUDE_CODE_OAUTH_REFRESH_TOKEN` +
  `CLAUDE_CODE_OAUTH_SCOPES` lets `claude auth login` exchange a refresh
  token directly instead of opening a browser.

## 3. Feasibility findings

### F1: Data-plane proxy with client-managed auth: POSSIBLE

With `ANTHROPIC_BASE_URL=https://gw.workspaceguardrails.com/anthropic`
and no credential envs set, the CLI performs its normal `/login` browser
flow directly against claude.ai, stores credentials itself, and sends
every API request (with its own `Authorization` header, beta headers,
and `?beta=true` query) to the gateway. A gateway route that relays
method, path, query string, headers, body, and streaming response
untouched to `api.anthropic.com` is fully transparent. This needs zero
gateway-side auth logic: pass through everything.

### F2: Login/refresh traffic through the gateway: NO SUPPORTED PATH

OAuth endpoints are compile-time constants in the client, not derived
from `ANTHROPIC_BASE_URL`. The one official override,
`CLAUDE_CODE_CUSTOM_OAUTH_URL`, is allowlist-gated
(`ALLOWED_OAUTH_BASE_URLS`: two FedStart hosts and one internal staging
host) and throws `CLAUDE_CODE_CUSTOM_OAUTH_URL is not an approved
endpoint.` for any other value, deliberately, to keep OAuth tokens from
leaving Anthropic-controlled endpoints. Our domain cannot be approved
by us.

An off-label spoof exists and is rejected for design: `USER_TYPE=ant` +
`USE_LOCAL_OAUTH=1` plus `CLAUDE_CODE_LOCAL_API_BASE`-style envs switch
the client to `getLocalOauthConfig()` whose bases are env-overridable;
but it also swaps CLIENT_ID to the internal dev id, renames the
credential store suffix, depends on an internal-build flag, and breaks
on any release that tightens the check. Documented here so nobody
rediscovers it as a "fix".

Consequence: for the passthrough provider the login and refresh legs
bypass the gateway by design (client talks to claude.ai /
platform.claude.com directly). The gateway proxies 100% of model
traffic including the auth headers on it; it does not see the handshake.

### F3: Upstream device flow: DOES NOT EXIST

Anthropic ships no RFC 8628 device authorization grant for Claude
accounts. Open feature requests: anthropics/claude-code issues #22992
and #24231 (headless/SSH users asking for exactly this). The only
headless path Anthropic documents is `claude setup-token`
(`CLAUDE_CODE_OAUTH_TOKEN`), a machine-transfer of a long-lived token.

A "device flow provider" therefore cannot proxy an upstream device
endpoint (there is none). It can only be a gateway facade, the same
shape as the existing kimi provider: the gateway issues the
user_code/device_code pair, hosts the verification page on any browser,
completes the upstream browser PKCE flow itself (section 2 mechanics),
stores the tokens, and hands clients a gateway session bearer. That is
provider B.

### F4: opencode

opencode's standard mechanism for an Anthropic-type provider is a
models.dev-style provider block with a baseURL and an API key in its
auth store. It has no native claude.ai OAuth. For opencode the
transparent options are: provider A (it sends its own Anthropic key
through the gateway, key passes through like any header) or provider B
(gateway session token as the provider key; gateway custodies the real
OAuth upstream).

### F5: Client behavior differences on a non-first-party base URL

Documented in the official env-vars doc, relevant to transparency
claims: MCP tool search is disabled unless `ENABLE_TOOL_SEARCH=true`
(the gateway must forward `tool_reference` blocks if enabled), and as of
v2.1.196 Remote Control is disabled when `ANTHROPIC_BASE_URL` is not
`api.anthropic.com`. Everything else (models, streaming, tools,
count_tokens) behaves identically.

## 4. Risks

- **Header/query fidelity:** OAuth tokens only work on the beta path;
  any gateway mutation of `anthropic-beta`, `?beta=true`, or
  `Authorization` breaks the passthrough provider. The route must not
  rewrite headers at all.
- **Upstream endpoint migration:** constants moved
  console.anthropic.com to platform.claude.com and the authorize leg now
  hops through claude.com/cai. The custodial engine must keep its
  constants in one config block, not scatter them.
- **Off-label custody:** provider B authenticates as the public Claude
  Code client from gateway infrastructure. The same class of risk the
  kimi/openai oauth providers already carry (consumer terms are written
  around first-party clients); acceptable to this deployment, flagged
  for the record.
- **Client-side disablement:** any wrapper or environment that sets
  `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` kills the OAuth
  path outright (F1). The wrapper must set only the base URL.

## 5. Conclusion

| Plane | Proxiable through GW | Mode |
|-------|---------------------|------|
| Model traffic incl. client's auth headers | Yes, fully | Provider A: bare passthrough, zero auth logic |
| Login (browser authorize + code exchange) | No (hardcoded client-side) | Bypasses GW; client-standard flow |
| Token refresh | No (hardcoded client-side) | Bypasses GW for A; GW-owned for B |
| Device-style login for headless/opencode | Not upstream; GW facade | Provider B: custodial, kimi-shaped |

This is the basis for REQ-PROVIDER-ANTHROPIC (two providers, A
passthrough and B custodial device facade) and the minimal
`res/scripts/claude-gw.sh` wrapper, which sets exactly one environment
variable: `ANTHROPIC_BASE_URL`.
