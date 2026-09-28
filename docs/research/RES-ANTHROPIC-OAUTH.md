# RES-ANTHROPIC-OAUTH: Can the Gateway Proxy Anthropic Auth?

**Date:** 2026-09-28
**Status:** Research complete
**Related:** [REQ-PROVIDER-ANTHROPIC](../requirements/REQ-PROVIDER-ANTHROPIC.md), [SPEC-PROVIDER-ANTHROPIC](../specifications/SPEC-PROVIDER-ANTHROPIC.md)

> Answers one question: can WORKSPACE-GATEWAY proxy Anthropic end to end,
> including all authentication, while downstream clients (claude, opencode)
> keep using their own standard credential mechanisms with zero user
> configuration? Short answer: the data plane yes, fully; the login and
> refresh plane no supported path exists (the CLI hardcodes it, and the
> sanctioned clients are designed to talk to Anthropic directly). The
> conclusion drives one gateway API-key provider plus a subscription path
> on the built-in OpenCode `anthropic` provider whose OAuth runs in a
> maintained community plugin, while the gateway proxies model traffic only
> and holds no Anthropic credential. Sources: Claude Code
> published source (`src/constants/oauth.ts`, `src/services/oauth/*`,
> `src/utils/auth.ts`, `src/services/api/client.ts`), OpenCode's installed
> plugin SDK types and provider-connect UI strings, the official env-vars
> and authentication docs, and community reimplementations.

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
| loopback callback | `http://localhost:<ephemeral>/callback` (client-chosen port, path `/callback`) |

Protocol quirks that any reimplementation must copy exactly
(`src/services/oauth/crypto.ts`, `auth-code-listener.ts`, `client.ts`):

- PKCE S256 with a 43-char base64url verifier (`base64url(randomBytes(32))`).
- **`state` is generated independently** (`generateState()` = a second
  `base64url(randomBytes(32))`), NOT a copy of the verifier. The loopback
  listener rejects the callback unless `state === expectedState`, and the
  token exchange submits `state`. An earlier note in this document
  claiming `state == code_verifier` was wrong and is corrected here; the
  custody design that depended on it was removed.
- The authorize URL carries `code=true` (upsell page variant).
- The manual callback returns `CODE#STATE`; the client splits on `#` and
  the state half must equal the generated state.
- Token exchange AND refresh are `Content-Type: application/json` bodies
  (not form-encoded); exchange includes `state`; refresh may expand scopes.
- Scopes: union of console (`org:create_api_key`, `user:profile`) and
  Claude.ai (`user:profile`, `user:inference`,
  `user:sessions:claude_code`, `user:mcp_servers`, `user:file_upload`).
- Access tokens are short-lived (hours); the client refreshes on its own
  schedule; refresh responses may omit a new refresh token (keep old).
- Provisioning env pair: `CLAUDE_CODE_OAUTH_REFRESH_TOKEN` +
  `CLAUDE_CODE_OAUTH_SCOPES` lets `claude auth login` exchange a refresh
  token directly instead of opening a browser.

## 3. Feasibility findings

### F1: Data-plane proxy with client-managed auth: POSSIBLE

With `ANTHROPIC_BASE_URL` pointing at the gateway `/anthropic` route and
no credential envs set, the CLI performs its normal `/login` browser
flow directly against claude.ai, stores credentials itself, and sends
every API request (with its own `Authorization` header, beta headers,
and `?beta=true` query) to the gateway. A route that relays method,
path, query string, headers, body, and streaming response untouched to
`api.anthropic.com` is fully transparent. This needs zero gateway-side
auth logic: pass through everything.

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

Consequence: the login and refresh legs bypass the gateway by design
(client talks to claude.ai / platform.claude.com directly). The gateway
proxies 100% of model traffic including the auth headers on it; it does
not see the handshake.

### F3: Upstream device flow: DOES NOT EXIST

Anthropic ships no RFC 8628 device authorization grant for Claude
accounts. Open feature requests: anthropics/claude-code issues #22992
and #24231 (headless/SSH users asking for exactly this). The only
headless path Anthropic documents is `claude setup-token`
(`CLAUDE_CODE_OAUTH_TOKEN`), a machine-transfer of a long-lived token.

Because there is no upstream device endpoint, an RFC 8628-style facade
would have to be invented and hosted by the gateway; the gateway would
then mint, store, and refresh a Claude Code subscription token from its
own infrastructure. That is exactly the subscription-reuse the gateway
must not perform (the service would become the party in breach).
Rejected: the gateway hosts no Anthropic auth surface.

### F4: opencode: NO BUILT-IN ANTHROPIC AUTH; CLIENT-SIDE PLUGIN REQUIRED

OpenCode's auth methods are registered by plugins and dispatched per
provider id (`ProviderAuth` in `packages/opencode/src/provider/auth.ts`:
`hooks[providerID]`; `authorize`/`callback` index
`hooks[input.providerID].methods`). Inspecting the installed OpenCode
1.18.31 binary (`opencode-linux-x64/bin/opencode`) shows compiled `auth`
hooks for exactly: `openai`, `xai`, `poe`, `gitlab`, `digitalocean`,
`github-copilot`, `snowflake-cortex`, `azure`, `cloudflare-workers-ai`,
`cloudflare-ai-gateway`. There is **no** `auth:{provider:"anthropic"}`
hook, no `opencode-anthropic-auth` plugin, and no `claude.ai` /
`oauth-2025-04-20` constant anywhere in the build. The
`provider.connect.title.anthropicProMax` i18n string and
`dialog.provider.anthropic.note` remain, but the UI reaches that title
only when a plugin registers an oauth method whose label contains "max"
for provider `anthropic`.

Consequences:

- "Claude Pro/Max" is **not** available out of the box in 1.18.31; a
  plugin must supply it. (Earlier builds bundled a subscription-reuse
  plugin; OpenCode removed it as of 1.3.0 while keeping the generic
  auth-hook mechanism.)
- Auth is keyed by provider id, so a second Anthropic provider on a new
  id cannot reuse an `anthropic`-keyed hook; it needs its own
  registered hook. This is also why no static config fragment can give a
  new provider native subscription auth.
- The repository therefore depends on the maintained community plugin
  `@ex-machina/opencode-anthropic-auth` (MIT; two active release trains,
  OpenCode v1 `latest` / v2 `next`), added to the OpenCode `plugin`
  array. It registers the `Claude Pro/Max` method on the **built-in**
  `anthropic` provider and performs the Anthropic OAuth exchange in the
  OpenCode process (client id, authorize/token endpoints, manual
  `CODE#STATE` callback), injecting the bearer, `anthropic-beta`, and the
  Claude Code request shape on inference requests. It routes model
  traffic through the gateway via `ANTHROPIC_BASE_URL`. The gateway sees
  only the resulting bearer on the passthrough route.
- The built-in `anthropic` provider is not defined or overridden on disk:
  no `provider.anthropic` block and no static fragment is committed.
  Routing is injected at runtime via `ANTHROPIC_BASE_URL`; the installer
  (`res/scripts/opencode-anthropic-max.sh`) only adds the plugin spec.

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
  hops through claude.com/cai. Because the client owns these constants,
  the gateway is insulated; it only has to stop rewriting headers.
- **Client-side disablement:** any wrapper or environment that sets
  `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` kills the OAuth
  path outright (F1). The wrapper must set only the base URL.
- **Jurisdiction:** the subscription reuse is performed by the user's
  OpenCode client configuration against Anthropic, outside the gateway
  service. Flagged for the record; the gateway itself carries no
  Anthropic credential.

## 5. Conclusion

| Plane | Proxiable through GW | Mode |
|-------|---------------------|------|
| Model traffic incl. client's auth headers | Yes, fully | Bare passthrough, zero auth logic |
| Login (browser authorize + code exchange) | No (client-owned) | Community plugin `@ex-machina/opencode-anthropic-auth` on the built-in `anthropic` provider |
| Token refresh | No (client-owned) | Client-side OpenCode/OAuth refresh |
| Device-style login | Not upstream | Rejected; no gateway facade |

This is the basis for REQ-PROVIDER-ANTHROPIC (one gateway API-key
provider plus a zero-gateway-auth subscription path on the built-in
provider), the minimal `res/scripts/claude-gw.sh` wrapper (sets exactly
one environment variable), and the community plugin that supplies the
subscription method the OpenCode build no longer ships.
