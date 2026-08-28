import { describe, expect, it } from "bun:test"
import plugin from "./workspace-gateway-auth"

const gateway = "http://gateway.test"
const originalFetch = globalThis.fetch

function response(value: unknown, status = 200) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "Content-Type": "application/json" },
  })
}

function mockProviderDetail(id: string, methods: Array<{ id: string; flow: string; route: string }>) {
  return (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input)
    if (url === `${gateway}/gateway/providers/${id}/opencode`) {
      expect(init?.method).toBe("GET")
      return Promise.resolve(response({ auth_type: "oauth", auth_methods: methods }))
    }
    return originalFetch(input, init)
  }
}

describe("workspace gateway auth plugin", () => {
  it("registers methods from provider metadata (OpenAI: browser + device)", async () => {
    globalThis.fetch = mockProviderDetail("workspace-gw-openai-device-oauth", [
      { id: "chatgpt-browser", flow: "authorization_code_pkce", route: "/openai/auth" },
      { id: "chatgpt-headless", flow: "device_authorization", route: "/openai/auth" },
    ]) as typeof globalThis.fetch
    try {
      const hooks = await plugin({} as never, {
        gateway,
        provider: "workspace-gw-openai-device-oauth",
      })
      expect(hooks.auth?.provider).toBe("workspace-gw-openai-device-oauth")
      expect(hooks.auth?.methods.map((method) => method.label)).toEqual(["chatgpt-browser", "chatgpt-headless"])
    } finally {
      globalThis.fetch = originalFetch
    }
  })

  it("registers methods from provider metadata (Kimi: device only)", async () => {
    globalThis.fetch = mockProviderDetail("workspace-gw-kimi-device-oauth", [
      { id: "kimi-device-oauth", flow: "device_authorization", route: "/kimi/auth" },
    ]) as typeof globalThis.fetch
    try {
      const hooks = await plugin({} as never, {
        gateway,
        provider: "workspace-gw-kimi-device-oauth",
      })
      expect(hooks.auth?.provider).toBe("workspace-gw-kimi-device-oauth")
      expect(hooks.auth?.methods.map((method) => method.label)).toEqual(["kimi-device-oauth"])
    } finally {
      globalThis.fetch = originalFetch
    }
  })

  it("rejects providers without OAuth methods", async () => {
    globalThis.fetch = mockProviderDetail("workspace-gw-kimi-api-key", []) as typeof globalThis.fetch
    try {
      await expect(
        plugin({} as never, { gateway, provider: "workspace-gw-kimi-api-key" }),
      ).rejects.toThrow("advertises no OAuth methods")
    } finally {
      globalThis.fetch = originalFetch
    }
  })

  it("rejects unsupported flows", async () => {
    globalThis.fetch = mockProviderDetail("workspace-gw-test", [
      { id: "mystery", flow: "client_credentials", route: "/test/auth" },
    ]) as typeof globalThis.fetch
    try {
      await expect(
        plugin({} as never, { gateway, provider: "workspace-gw-test" }),
      ).rejects.toThrow("unsupported OAuth flow")
    } finally {
      globalThis.fetch = originalFetch
    }
  })

  it("completes the device flow through the gateway", async () => {
    let polls = 0
    globalThis.fetch = (async (input, init) => {
      const url = String(input)
      if (url === `${gateway}/gateway/providers/workspace-gw-kimi-device-oauth/opencode`) {
        return response({
          auth_type: "oauth",
          auth_methods: [
            { id: "kimi-device-oauth", flow: "device_authorization", route: "/kimi/auth" },
          ],
        })
      }
      if (url === `${gateway}/kimi/auth/device`) {
        expect(init?.method).toBe("POST")
        return response({
          device_code: "gateway-device",
          verification_uri_complete: "https://kimi.test/device?code=TEST",
          interval: 0,
          expires_in: 60,
        })
      }
      if (url === `${gateway}/kimi/auth/device/poll`) {
        polls += 1
        return polls === 1
          ? response({ error: "authorization_pending", error_code: "authorization_pending" }, 202)
          : response({ access_token: "gateway-access" })
      }
      return originalFetch(input, init)
    }) as typeof globalThis.fetch
    try {
      const hooks = await plugin({} as never, {
        gateway,
        provider: "workspace-gw-kimi-device-oauth",
      })
      const method = hooks.auth!.methods[0] as {
        authorize: () => Promise<{ url: string; callback: () => Promise<unknown> }>
      }
      const authorization = await method.authorize!()
      expect(authorization.url).toBe("https://kimi.test/device?code=TEST")
      await expect(authorization.callback()).resolves.toEqual({ type: "success", key: "gateway-access" })
      expect(polls).toBe(2)
    } finally {
      globalThis.fetch = originalFetch
    }
  })

  it("validates browser callback state before gateway exchange", async () => {
    let callbackExchange = 0
    globalThis.fetch = (async (input, init) => {
      const url = String(input)
      if (url === `${gateway}/gateway/providers/workspace-gw-openai-device-oauth/opencode`) {
        return response({
          auth_type: "oauth",
          auth_methods: [
            { id: "chatgpt-browser", flow: "authorization_code_pkce", route: "/openai/auth" },
          ],
        })
      }
      if (url === `${gateway}/openai/auth/browser`) {
        expect(JSON.parse(String(init?.body))).toEqual({ redirect_uri: "http://localhost:1455/auth/callback" })
        return response({ authorization_url: "https://openai.test/authorize", state: "expected-state" })
      }
      if (url === `${gateway}/openai/auth/browser/callback`) {
        callbackExchange += 1
        return response({ access_token: "gateway-browser-access" })
      }
      return originalFetch(input, init)
    }) as typeof globalThis.fetch
    try {
      const hooks = await plugin({} as never, {
        gateway,
        provider: "workspace-gw-openai-device-oauth",
      })
      const method = hooks.auth!.methods[0] as {
        authorize: () => Promise<{ url: string; callback: () => Promise<unknown> }>
      }
      const authorization = await method.authorize!()
      await originalFetch("http://localhost:1455/auth/callback?code=CODE&state=wrong-state")
      await expect(authorization.callback()).resolves.toEqual({ type: "failed" })
      expect(callbackExchange).toBe(0)
    } finally {
      globalThis.fetch = originalFetch
    }
  })

  it("exchanges a browser callback after validating state", async () => {
    let callbackExchange = 0
    globalThis.fetch = (async (input, init) => {
      const url = String(input)
      if (url === `${gateway}/gateway/providers/workspace-gw-openai-device-oauth/opencode`) {
        return response({
          auth_type: "oauth",
          auth_methods: [
            { id: "chatgpt-browser", flow: "authorization_code_pkce", route: "/openai/auth" },
          ],
        })
      }
      if (url === `${gateway}/openai/auth/browser`) {
        return response({ authorization_url: "https://openai.test/authorize", state: "expected-state" })
      }
      if (url === `${gateway}/openai/auth/browser/callback`) {
        callbackExchange += 1
        expect(JSON.parse(String(init?.body))).toEqual({
          code: "CODE",
          state: "expected-state",
          redirect_uri: "http://localhost:1455/auth/callback",
        })
        return response({ access_token: "gateway-browser-access" })
      }
      return originalFetch(input, init)
    }) as typeof globalThis.fetch
    try {
      const hooks = await plugin({} as never, {
        gateway,
        provider: "workspace-gw-openai-device-oauth",
      })
      const method = hooks.auth!.methods[0] as {
        authorize: () => Promise<{ url: string; callback: () => Promise<unknown> }>
      }
      const authorization = await method.authorize!()
      await originalFetch("http://localhost:1455/auth/callback?code=CODE&state=expected-state")
      await expect(authorization.callback()).resolves.toEqual({ type: "success", key: "gateway-browser-access" })
      expect(callbackExchange).toBe(1)
    } finally {
      globalThis.fetch = originalFetch
    }
  })

  it("fails on a terminal device response", async () => {
    let polls = 0
    globalThis.fetch = (async (input, init) => {
      const url = String(input)
      if (url === `${gateway}/gateway/providers/workspace-gw-kimi-device-oauth/opencode`) {
        return response({
          auth_type: "oauth",
          auth_methods: [
            { id: "kimi-device-oauth", flow: "device_authorization", route: "/kimi/auth" },
          ],
        })
      }
      if (url === `${gateway}/kimi/auth/device`) {
        expect(init?.method).toBe("POST")
        return response({ device_code: "gateway-device", verification_uri: "https://kimi.test/device", interval: 0, expires_in: 60 })
      }
      if (url === `${gateway}/kimi/auth/device/poll`) {
        polls += 1
        return response({ error: "access_denied", error_code: "access_denied" }, 400)
      }
      return originalFetch(input, init)
    }) as typeof globalThis.fetch
    try {
      const hooks = await plugin({} as never, {
        gateway,
        provider: "workspace-gw-kimi-device-oauth",
      })
      const method = hooks.auth!.methods[0] as {
        authorize: () => Promise<{ callback: () => Promise<unknown> }>
      }
      const authorization = await method.authorize!()
      await expect(authorization.callback()).resolves.toEqual({ type: "failed" })
      expect(polls).toBe(1)
    } finally {
      globalThis.fetch = originalFetch
    }
  })

  it("continues polling after slow_down", async () => {
    const originalSetTimeout = globalThis.setTimeout
    let polls = 0
    globalThis.setTimeout = ((handler: TimerHandler, _timeout: number | undefined, ...args: any[]) =>
      originalSetTimeout(handler, 0, ...args)) as typeof globalThis.setTimeout
    globalThis.fetch = (async (input, init) => {
      const url = String(input)
      if (url === `${gateway}/gateway/providers/workspace-gw-kimi-device-oauth/opencode`) {
        return response({
          auth_type: "oauth",
          auth_methods: [
            { id: "kimi-device-oauth", flow: "device_authorization", route: "/kimi/auth" },
          ],
        })
      }
      if (url === `${gateway}/kimi/auth/device`) {
        expect(init?.method).toBe("POST")
        return response({ device_code: "gateway-device", verification_uri: "https://kimi.test/device", interval: 0, expires_in: 60 })
      }
      if (url === `${gateway}/kimi/auth/device/poll`) {
        polls += 1
        return polls === 1
          ? response({ error: "slow_down", error_code: "slow_down" }, 202)
          : response({ access_token: "gateway-access" })
      }
      return originalFetch(input, init)
    }) as typeof globalThis.fetch
    try {
      const hooks = await plugin({} as never, {
        gateway,
        provider: "workspace-gw-kimi-device-oauth",
      })
      const method = hooks.auth!.methods[0] as {
        authorize: () => Promise<{ callback: () => Promise<unknown> }>
      }
      const authorization = await method.authorize!()
      await expect(authorization.callback()).resolves.toEqual({ type: "success", key: "gateway-access" })
      expect(polls).toBe(2)
    } finally {
      globalThis.fetch = originalFetch
      globalThis.setTimeout = originalSetTimeout
    }
  })
})
