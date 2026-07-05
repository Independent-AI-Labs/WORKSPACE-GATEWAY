# LLM Gateway Plugin Documentation

**Project:** WORKSPACE-GATEWAY : High-Performance Enterprise Multi-Tenant LLM Gateway
**Status:** Draft specs (research-validated)
**Date:** 2026-07-04

## Index

| Document | Scope |
|----------|-------|
| [`PROPOSAL-LLM-GATEWAY-v2.md`](PROPOSAL-LLM-GATEWAY-v2.md) | Revised architecture proposal (supersedes v1.0) : the umbrella design |
| `PLUGIN-FOUNDATION.md` | Shared build/host/sidecar foundation for all custom Rust Proxy-Wasm filters; meta.json schema, dispatch_http_call contract, state model, error discipline |
| `PLUGIN-REDACT-LUA.md` | Thin in-process Lua Kong plugin : buffers request to the redaction engine cosocket, stashes PII map in kong.ctx.plugin, re-hydrates in body_filter (local gsub, no cosocket allowed there) |
| `PLUGIN-REDACT-ENGINE.md` | Standalone Rust redaction binary sidecar : aho-corasick + regex + optional tract ONNX NER; POST /redact, /restore, /healthz; mTLS, no PII in logs |
| `PLUGIN-AUTH-OIDC.md` | Rust Proxy-Wasm filter : stateless JWT validation against cached JWKS; multi-issuer (Keycloak + Entra), `dispatch_http_call` refresh, RFC 6750 error responses |
| `PLUGIN-AUTH-LDAP.md` | Rust Proxy-Wasm filter + Rust Axum bridge sidecar : legacy AD via LDAP/Kerberos; pause-dispatch-resume to a small HTTP→LDAP/Kerberos bridge holding the keytab |
| `PLUGIN-SEMANTIC-CACHE.md` | Rust Proxy-Wasm filter + Redis VSS shim : semantic cache for chat completions via dispatch_http_call (no socket in wasm); cross-tenant TAG filtering; graceful MISS on infra failure |
| `PLUGIN-FAILOVER.md` | Lua Kong plugin + Rust translator sidecar for Bedrock/Anthropic : weighted LB in `ngx.shared.dict`, circuit breaker, nginx `proxy_next_upstream` for streaming-safe failover, provider format translation |

## Build Targets (per spec)

- Rust Proxy-Wasm plugins: `cargo build --release --target wasm32-wasip1` (Rust 1.84+);
  core-wasm modules, NOT components; pin `proxy-wasm = "0.2.5"`.
- Rust native sidecars (redaction engine, LDAP bridge, failover translator): binary
  `cargo build --release --target x86_64-unknown-linux-gnu`. SIMD available.
- Lua plugins: load as custom Kong plugin dirs; verify schema/local priority placement
  in decK config.

## License Posture

All four custom plugins replace Kong Enterprise-only functionality:
- `ai-proxy-advanced` → `PLUGIN-FAILOVER`
- `ai-semantic-cache` → `PLUGIN-SEMANTIC-CACHE`
- `openid-connect` → `PLUGIN-AUTH-OIDC`
- `ldap-auth-advanced` → `PLUGIN-AUTH-LDAP`

The redaction plugin is custom (no Enterprise equivalent except `ai-sanitizer`, which
already delegates to an external PII service : we replicate the same pattern with our
own Rust engine).

The underlying Kong data plane is **Kong Gateway 3.14** (`kong/kong-gateway:3.14.0.4-debian`,
Enterprise image run unlicensed): `ai-proxy` (bundled), `http-log`/`tcp-log` (bundled), and the
Wasm host (`ngx_wasm_module`, GA in 3.11) all work without a license in 3.14 free mode.
Kong runs in **traditional mode with PostgreSQL** (provided by DATAOPS `ami-postgres`),
enabling writable Admin API, decK `gateway sync` for GitOps, and restart-survivability.
No Enterprise license required for normal operation. See
`PROPOSAL-LLM-GATEWAY-v2.md` Section 0 for the full OSS-vs-Enterprise correction table.

## Reading Order

1. `PROPOSAL-LLM-GATEWAY-v2.md` : the umbrella architecture & rationale for splitting
   into these plugins.
2. `PLUGIN-FOUNDATION.md` : shared build/host/state contracts; everything else
   inherits this.
3. Per-plugin specs in any order; consult the relevant one during implementation.