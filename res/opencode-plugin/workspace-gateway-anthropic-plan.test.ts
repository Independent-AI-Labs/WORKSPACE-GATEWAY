import { afterEach, beforeEach, describe, expect, it } from "bun:test"
import plugin from "./workspace-gateway-anthropic-plan"

const OUR_ID = "workspace-gw-anthropic-coding-plan-passthrough"
const LOGIN_ID = "anthropic"
const originalFetch = globalThis.fetch
const originalBaseUrl = process.env.ANTHROPIC_BASE_URL

type SetCall = { path?: { id?: string }; body?: { type?: string } }

function makeInput(captured: { set?: SetCall }) {
  return {
    client: {
      auth: {
        set: (args: SetCall) => {
          captured.set = args
          return Promise.resolve({})
        },
      },
      app: { log: () => Promise.resolve({}) },
    },
  } as unknown as Parameters<typeof plugin>[0]
}

function sseResponse() {
  return new Response('data: {"type":"message_stop"}\n\n', {
    status: 200,
    headers: { "content-type": "text/event-stream" },
  })
}

function oauthAuth(overrides: Record<string, unknown> = {}) {
  return () =>
    Promise.resolve({
      type: "oauth",
      access: "access-token",
      refresh: "refresh-token",
      expires: Date.now() + 3_600_000,
      ...overrides,
    }) as never
}

describe("workspace gateway anthropic-plan plugin", () => {
  beforeEach(() => {
    delete process.env.ANTHROPIC_BASE_URL
  })

  afterEach(() => {
    globalThis.fetch = originalFetch
    if (originalBaseUrl === undefined) delete process.env.ANTHROPIC_BASE_URL
    else process.env.ANTHROPIC_BASE_URL = originalBaseUrl
  })

  it("re-keys the community OAuth hook to the gateway provider id", async () => {
    const hooks = await plugin(makeInput({}), { provider: OUR_ID })
    expect(hooks.auth?.provider).toBe(OUR_ID)
    expect(hooks.auth?.methods.map((method) => method.label)).toContain("Claude Pro/Max")
  })

  it("requires a provider option", async () => {
    await expect(plugin(makeInput({}), {})).rejects.toThrow("requires a provider option")
  })

  it("adds ?beta=true for prefixed /v1/messages and keeps the gateway origin", async () => {
    let requested = ""
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      requested = String(input)
      return sseResponse()
    }) as typeof globalThis.fetch

    const hooks = await plugin(makeInput({}), { provider: OUR_ID })
    const loader = hooks.auth!.loader!
    const options = (await loader(oauthAuth(), { models: {} } as never)) as { fetch: (i: unknown, init?: unknown) => Promise<unknown> }
    await options.fetch("http://gateway.test/anthropic-coding-plan/v1/messages", {
      method: "POST",
      body: JSON.stringify({ messages: [{ role: "user", content: "hi" }] }),
    })

    const url = new URL(requested)
    expect(url.origin).toBe("http://gateway.test")
    expect(url.pathname).toBe("/anthropic-coding-plan/v1/messages")
    expect(url.searchParams.get("beta")).toBe("true")
  })

  it("does not add beta to non-messages paths", async () => {
    let requested = ""
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      requested = String(input)
      return sseResponse()
    }) as typeof globalThis.fetch

    const hooks = await plugin(makeInput({}), { provider: OUR_ID })
    const loader = hooks.auth!.loader!
    const options = (await loader(oauthAuth(), { models: {} } as never)) as { fetch: (i: unknown, init?: unknown) => Promise<unknown> }
    await options.fetch("http://gateway.test/anthropic-coding-plan/v1/messages/count_tokens", {
      method: "POST",
      body: JSON.stringify({ messages: [{ role: "user", content: "hi" }] }),
    })

    expect(new URL(requested).searchParams.has("beta")).toBe(false)
  })

  it("persists refreshed tokens under the gateway provider id, not 'anthropic'", async () => {
    const captured: { set?: SetCall } = {}
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      const url = String(input)
      if (url === "https://platform.claude.com/v1/oauth/token") {
        return new Response(JSON.stringify({ access_token: "new-access", refresh_token: "new-refresh", expires_in: 3600 }), {
          status: 200,
          headers: { "content-type": "application/json" },
        })
      }
      return sseResponse()
    }) as typeof globalThis.fetch

    const hooks = await plugin(makeInput(captured), { provider: OUR_ID })
    const loader = hooks.auth!.loader!
    // Expired access token forces the community plugin's refresh path.
    const options = (await loader(
      oauthAuth({ access: "", expires: 0 }),
      { models: {} } as never,
    )) as { fetch: (i: unknown, init?: unknown) => Promise<unknown> }
    await options.fetch("http://gateway.test/anthropic-coding-plan/v1/messages", {
      method: "POST",
      body: JSON.stringify({ messages: [{ role: "user", content: "hi" }] }),
    })

    expect(captured.set?.path?.id).toBe(OUR_ID)
    expect(captured.set?.path?.id).not.toBe(LOGIN_ID)
    expect(captured.set?.body?.type).toBe("oauth")
  })
})