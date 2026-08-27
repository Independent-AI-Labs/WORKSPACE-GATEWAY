import { createServer, type Server } from "node:http"
import type { Hooks, Plugin, PluginOptions } from "@opencode-ai/plugin"

const CALLBACK_PORT = 1455
const CALLBACK_URI = `http://localhost:${CALLBACK_PORT}/auth/callback`

type Options = PluginOptions & {
  gateway?: string
  provider?: string
  route?: string
}

type CallbackValue = {
  code?: string
  state?: string
  error?: string
  error_description?: string
}

type BrowserStart = {
  authorization_url: string
  state: string
}

type DeviceStart = {
  device_code: string
  verification_uri?: string
  verification_uri_complete?: string
  interval?: number
  expires_in?: number
}

type TokenResponse = {
  access_token?: string
  error?: string
  error_code?: string
}

function callbackServer() {
  let server: Server | undefined
  let resolveCallback: ((value: CallbackValue) => void) | undefined
  let rejectCallback: ((error: Error) => void) | undefined
  const callback = new Promise<CallbackValue>((resolve, reject) => {
    resolveCallback = resolve
    rejectCallback = reject
  })

  server = createServer((request, response) => {
    const requestPath = request.url ? request.url : "/"
    const url = new URL(requestPath, CALLBACK_URI)
    if (url.pathname !== "/auth/callback") {
      response.writeHead(404).end("Not found")
      return
    }
    const value: CallbackValue = {
      code: url.searchParams.get("code") ?? undefined,
      state: url.searchParams.get("state") ?? undefined,
      error: url.searchParams.get("error") ?? undefined,
      error_description: url.searchParams.get("error_description") ?? undefined,
    }
    resolveCallback?.(value)
    response.writeHead(value.error ? 400 : 200, { "Content-Type": "text/plain" })
    const message = value.error ? value.error : "Authentication received. You may close this tab."
    response.end(message)
  })

  const ready = new Promise<void>((resolve, reject) => {
    server!.once("error", reject)
    server!.listen(CALLBACK_PORT, "localhost", resolve)
  })

  return {
    callback,
    ready,
    close() {
      rejectCallback?.(new Error("OAuth callback server closed"))
      server?.close()
      server = undefined
    },
  }
}

function gatewayUrl(options: Options, path: string) {
  let gateway = options.gateway
  if (!gateway) gateway = process.env.WORKSPACE_GATEWAY_URL
  if (!gateway) gateway = "http://localhost:9080"
  gateway = gateway.replace(/\/$/, "")
  return `${gateway}${path}`
}

async function request<T>(options: Options, path: string, init: RequestInit, acceptedStatuses: number[] = []): Promise<T> {
  const headers = new Headers(init.headers)
  headers.set("Accept", "application/json")
  headers.set("Content-Type", "application/json")
  const response = await fetch(gatewayUrl(options, path), {
    ...init,
    headers,
  })
  const body = await response.json().catch(() => ({}))
  if (!response.ok && !acceptedStatuses.includes(response.status)) {
    throw new Error(`Workspace gateway OAuth request failed: HTTP ${response.status}`)
  }
  return body as T
}

function browserMethod(options: Options, route: string) {
  return {
    label: "ChatGPT Pro/Plus (browser)",
    type: "oauth" as const,
    authorize: async () => {
      const callback = callbackServer()
      try {
        await callback.ready
        const started = await request<BrowserStart>(options, `${route}/browser`, {
          method: "POST",
          body: JSON.stringify({ redirect_uri: CALLBACK_URI }),
        })
        return {
          url: started.authorization_url,
          instructions: "Complete authorization in your browser. This window will close automatically.",
          method: "auto" as const,
          callback: async () => {
            try {
              const value = await callback.callback
              if (value.error || !value.code || value.state !== started.state) return { type: "failed" as const }
              const token = await request<{ access_token?: string }>(options, `${route}/browser/callback`, {
                method: "POST",
                body: JSON.stringify({ code: value.code, state: value.state, redirect_uri: CALLBACK_URI }),
              })
              if (!token.access_token) return { type: "failed" as const }
              return { type: "success" as const, key: token.access_token }
            } catch {
              return { type: "failed" as const }
            } finally {
              callback.close()
            }
          },
        }
      } catch (error) {
        callback.close()
        throw error
      }
    },
  }
}

function deviceMethod(options: Options, route: string, label: string) {
  return {
    label,
    type: "oauth" as const,
    authorize: async () => {
      const started = await request<DeviceStart>(options, `${route}/device`, { method: "POST" })
      const intervalSeconds = started.interval === undefined ? 5 : started.interval
      const expiresInSeconds = started.expires_in === undefined ? 900 : started.expires_in
      const interval = Math.max(intervalSeconds, 1) * 1000
      const deadline = Date.now() + expiresInSeconds * 1000
      let verificationUrl = ""
      if (started.verification_uri_complete) verificationUrl = started.verification_uri_complete
      else if (started.verification_uri) verificationUrl = started.verification_uri
      return {
        url: verificationUrl,
        instructions: "Complete authorization in your browser. The login will continue automatically.",
        method: "auto" as const,
        callback: async () => {
          while (Date.now() < deadline) {
            const result = await request<TokenResponse>(
              options,
              `${route}/device/poll`,
              {
                method: "POST",
                body: JSON.stringify({ device_code: started.device_code }),
              },
              [202],
            ).catch((): TokenResponse => ({ error: "request_failed" }))
            if (result.access_token) return { type: "success" as const, key: result.access_token }
            const error = result.error_code ?? result.error
            if (error !== "authorization_pending" && error !== "slow_down") return { type: "failed" as const }
            await new Promise((resolve) => setTimeout(resolve, error === "slow_down" ? interval + 5000 : interval))
          }
          return { type: "failed" as const }
        },
      }
    },
  }
}

const plugin: Plugin = async (_input, rawOptions) => {
  const options = rawOptions as Options
  const provider = options.provider
  const route = options.route
  if (!provider || !route) throw new Error("workspace-gateway-auth requires provider and route options")

  if (provider === "workspace-gw-openai-device-oauth") {
    return {
      auth: {
        provider,
        methods: [browserMethod(options, route), deviceMethod(options, route, "ChatGPT Pro/Plus (headless)")],
      },
    }
  }

  if (provider === "workspace-gw-kimi-device-oauth") {
    return {
      auth: {
        provider,
        methods: [deviceMethod(options, route, "Kimi Code (device authorization)")],
      },
    }
  }

  throw new Error(`Unsupported workspace gateway auth provider: ${provider}`)
}

export default plugin
