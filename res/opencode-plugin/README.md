# Workspace Gateway OpenCode Auth Plugin

This plugin is owned by `WORKSPACE-GATEWAY` and loaded by OpenCode through its
standard local plugin configuration. It is not part of OpenCode's source tree
and does not modify OpenCode's built-in plugins.

The plugin consumes the published `@opencode-ai/plugin` package through Bun.
The dependency is intentionally not a `workspace:*`
reference to `projects/opencode`, and the gateway does not copy or re-declare
the upstream plugin types.

Runtime and dependency setup follows the hermetic boot and generated-hook
conventions established by `WORKSPACE-CI` and `WORKSPACE-VM`. Bun is the
runtime requirement for this plugin; the workspace repositories remain the
source of truth for version pinning, boot layout, CI installation, lockfile
validation, and hook generation.

The plugin package root is `res/opencode-plugin/`. The published dependency is
pinned in its `package.json`, the Bun lockfile is `res/opencode-plugin/bun.lock`,
and the runtime pin is `bun@1.3.14`.

## Configuration

Add one plugin instance per gateway OAuth provider. The plugin fetches
`GET /gateway/providers/{id}/opencode` at load time and registers one auth
method per entry in `auth_methods`, dispatching by `flow`
(`device_authorization` or `authorization_code_pkce`); routes come from the
method metadata, so no provider or route is hard-coded in the plugin:

```json
{
  "plugin": [
    [
      "file:///absolute/path/to/WORKSPACE-GATEWAY/res/opencode-plugin/workspace-gateway-auth.ts",
      {
        "provider": "workspace-gw-openai-device-oauth",
        "gateway": "http://localhost:9080"
      }
    ],
    [
      "file:///absolute/path/to/WORKSPACE-GATEWAY/res/opencode-plugin/workspace-gateway-auth.ts",
      {
        "provider": "workspace-gw-kimi-device-oauth",
        "gateway": "http://localhost:9080"
      }
    ]
  ]
}
```

OpenAI advertises both browser PKCE and headless device methods; Kimi
advertises only its verified device-authorization method. The set of methods
is whatever provider-sync declares for the provider.

The plugin returns gateway-issued credentials as OpenCode API credentials. The
gateway retains upstream refresh tokens and performs upstream refresh; the
plugin never contacts upstream OAuth endpoints directly and never hosts an
inline interpreter callback server.

## Tests

The unit test is `workspace-gateway-auth.test.ts`. Prefer the Make targets,
which pin the Bun binary and working directory:

```bash
make plugin-install BUN="$BUN"        # bun install --frozen-lockfile
make plugin-type-check BUN="$BUN"     # tsc --noEmit via the local toolchain
make plugin-test BUN="$BUN"           # bun test workspace-gateway-auth.test.ts
```

Direct invocation (equivalent, from the repository root):

```bash
cd res/opencode-plugin
bun install --frozen-lockfile
bun ./node_modules/typescript/bin/tsc --noEmit
bun test workspace-gateway-auth.test.ts
```

The test covers method registration, pending and slow-down device polling,
terminal device errors, browser callback success, browser callback state
validation, and prevention of a gateway callback exchange on invalid state.

## Packaging Invariants

- Keep the published `@opencode-ai/plugin` dependency in the gateway-owned Bun
  manifest and lockfile.
- Keep `import type { Hooks, Plugin, PluginOptions } from
  "@opencode-ai/plugin"` aligned with the public package; do not replace it
  with local structural types.
- Keep tests on `bun:test`; do not convert them to Node's test runner.
- Do not modify `projects/opencode` to make this plugin build.
- Do not add an inline Python, Perl, or Node callback server to
  `res/scripts/opencode-provider-login.sh`.
