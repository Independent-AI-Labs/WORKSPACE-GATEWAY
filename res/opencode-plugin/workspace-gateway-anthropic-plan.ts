import { AnthropicAuthPlugin } from "@ex-machina/opencode-anthropic-auth"
import type { Hooks, Plugin, PluginInput, PluginOptions } from "@opencode-ai/plugin"

// Client-side thin wrapper over the community Anthropic auth plugin
// (@ex-machina/opencode-anthropic-auth). The gateway never touches Anthropic
// auth: this module only re-keys the community plugin's OAuth hook from its
// hardcoded "anthropic" provider id to a gateway provider id, so the same
// Claude Pro/Max PKCE flow can be offered on a config provider through
// OpenCode's standard Hooks.auth mechanism.
//
// Three upstream behaviours are adapted, each a documented ceiling of the
// pinned community plugin:
//   1. auth.provider is hardcoded to "anthropic" -> set it to our provider id.
//   2. Token-refresh persistence is hardcoded to auth.set(id: "anthropic") ->
//      proxy the client so that write lands under our provider id.
//   3. `?beta=true` is only added when the request pathname is exactly
//      "/v1/messages", but a gateway route prefixes the path
//      ("/anthropic-coding-plan/v1/messages") -> append beta ourselves.
// ponytail: re-keys a pinned external plugin (1.8.5); bump-and-retest if that
// plugin changes its hardcoded provider id or URL-rewrite contract.

type Options = PluginOptions & {
  provider?: string
  gateway?: string
}

function providerScopedClient(client: PluginInput["client"], provider: string): PluginInput["client"] {
  return new Proxy(client as object, {
    get(target, property, receiver) {
      if (property !== "auth") return Reflect.get(target, property, receiver)
      const auth = Reflect.get(target, property, receiver) as {
        set?: (args: { path?: { id?: string } } & Record<string, unknown>) => unknown
      }
      if (!auth || typeof auth.set !== "function") return auth
      return new Proxy(auth, {
        get(authTarget, authProperty, authReceiver) {
          if (authProperty !== "set") return Reflect.get(authTarget, authProperty, authReceiver)
          return (args: { path?: { id?: string } } & Record<string, unknown>) => {
            const rewritten =
              args && args.path && args.path.id === "anthropic"
                ? { ...args, path: { ...args.path, id: provider } }
                : args
            return (authTarget as { set: (a: unknown) => unknown }).set(rewritten)
          }
        },
      })
    },
  }) as PluginInput["client"]
}

function withBeta(input: RequestInfo | URL): RequestInfo | URL {
  let url: URL
  try {
    url = input instanceof Request ? new URL(input.url) : new URL(String(input))
  } catch {
    return input
  }
  if (!url.pathname.endsWith("/v1/messages")) return input
  if (url.searchParams.has("beta")) return input
  url.searchParams.set("beta", "true")
  return input instanceof Request ? new Request(url.toString(), input) : url
}

export const WorkspaceAnthropicPlanPlugin: Plugin = async (input, rawOptions) => {
  const options = rawOptions as Options
  const provider = options.provider
  if (!provider) throw new Error("workspace-gateway-anthropic-plan requires a provider option")

  const hooks: Hooks = await AnthropicAuthPlugin(
    { ...input, client: providerScopedClient(input.client, provider) },
    rawOptions,
  )
  if (!hooks.auth) throw new Error("workspace-gateway-anthropic-plan: community plugin returned no auth hook")

  // Re-key the hook from the community plugin's hardcoded "anthropic" to the
  // gateway provider id (OpenCode binds auth methods and getAuth by this id).
  hooks.auth.provider = provider

  const loader = hooks.auth.loader
  if (loader) {
    hooks.auth.loader = async (getAuth, providerInfo) => {
      const options = await loader(getAuth, providerInfo)
      if (options && typeof options.fetch === "function") {
        const innerFetch = options.fetch
        options.fetch = (requestInput: RequestInfo | URL, init?: RequestInit) =>
          innerFetch(withBeta(requestInput), init)
      }
      return options
    }
  }

  return hooks
}

export default WorkspaceAnthropicPlanPlugin