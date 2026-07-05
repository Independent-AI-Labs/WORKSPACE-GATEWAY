# Plugin Foundation Specification - Shared Build/Host Contract

**Document ID:** AMI-PROP-LLMGW-PLUGIN-FOUNDATION-v1.0
**Status:** Draft
**Date:** 2026-07-04
**Parent:** `PROPOSAL-LLM-GATEWAY-v2.md` (AMI-PROP-LLMGW-v2.0)
**Scope:** Shared engineering foundation for all four custom Rust Proxy-Wasm filters
(`PLUGIN-AUTH-OIDC`, `PLUGIN-AUTH-LDAP`, `PLUGIN-SEMANTIC-CACHE`, `PLUGIN-FAILOVER`)
running inside Kong Gateway 3.14's `ngx_wasm_module`.

This document is the authoritative base; each per-plugin spec inherits these contracts
and adds its own `config_schema`, callbacks, and sidecar APIs.

---

## 1. Target Platform

| Component | Version | Rationale |
|-----------|---------|-----------|
| Kong Gateway | 3.14 (`kong/kong-gateway:3.14.0.4-debian`) | Enterprise image run unlicensed; OSS features (Wasm, `ai-proxy`, custom plugins, Admin API) work in 3.14 free mode. Traditional mode with PostgreSQL ensures restart-survivability. |
| `ngx_wasm_module` | bundled with Kong 3.14 | Kong-authored Proxy-Wasm host ABI; Wasm toggle removed (GA) in 3.11 |
| Proxy-Wasm Rust SDK | `proxy-wasm = "0.2.5"` | Last stable 0.2.x; ABI v0.2.1 supported by ngx_wasm_module (0.3.0-dev unreleased) |
| Rust toolchain | `>= 1.84` (MSRV `1.85` for SDK master; pin 1.84 for 0.2.x) | 1.84 renamed `wasm32-wasi` to `wasm32-wasip1` |

**ABI note:** `0.3.0-dev` (master) is NOT released and uses edition 2024 / MSRV 1.85.
Do NOT depend on `master` until ngx_wasm_module declares ABI 0.3 support.

---

## 2. Build Toolchain

### 2.1 Project skeleton (canonical, per Kong's showcases)

```
my-filter/
  .cargo/config.toml      # [build] target = "wasm32-wasip1"
  Cargo.toml               # crate-type = ["cdylib"]; proxy-wasm = "0.2"
  src/filter.rs            # proxy_wasm::main! + Root + Http impls
  my_filter.meta.json      # Draft-4 JSON Schema config_schema
```

### 2.2 `.cargo/config.toml`

```toml
[build]
target = "wasm32-wasip1"
```

Toolchain setup: `rustup target add wasm32-wasip1` then `cargo build --release`
(outputs `target/wasm32-wasip1/release/<crate_name>.wasm`).
`wasm32-wasi` is the legacy name; byte-identical output, but pin `wasm32-wasip1`
on Rust 1.84+ to avoid deprecation warnings.

### 2.3 `Cargo.toml` baseline (filter crate)

```toml
[package]
name = "auth-oidc-filter"   # per-plugin: e.g. failover-filter, semantic-cache-filter
version = "1.0.0"
edition = "2021"             # SDK 0.2.x supports 2021; master is 2024 only
[lib]
path = "src/filter.rs"
crate-type = ["cdylib"]
[dependencies]
proxy-wasm = "0.2"
log = "0.4"
serde = { version = "1", features = ["derive"] }
serde-json-wasm = "0.5"     # NOT serde_json -- it pulls std filesystem/threading
[profile.release]
lto = true
opt-level = 3
codegen-units = 1
panic = "abort"             # panics trap rather than unwind the wasm instance
strip = "debuginfo"
```

### 2.4 Core-wasm module, NOT component model

Proxy-Wasm SDKs emit a **plain core Wasm module** (WASI preview-1) that imports
`proxy_*` host functions from the `env` module. `ngx_wasm_module` does NOT run a
Wasmtime/component runtime; a **Wasm component (component model) is NOT accepted**.
Do NOT wrap with `wasm-tools component new`. The `proxy_wasm` crate is designed for
core modules and `panic = "abort"` (set in the SDK release profile) ensures panics
trap rather than unwind.

---

## 3. Kong `meta.json` Schema + Filter Discovery

### 3.1 Discovery flow

Set in `kong.conf` (env `KONG_WASM_FILTERS_PATH`). Kong scans this directory at
startup for `.wasm` files. Each `.wasm` may have a sibling
`<name>.meta.json` (filename = `.wasm` basename with `.meta.json` suffix).
Enable Wasm: `KONG_WASM=on`.

### 3.2 `meta.json` validated schema (from `Kong/kong` `kong/runloop/wasm.lua`)

```json
{
  "config_schema": <JSON Schema (Draft 4) | optional>,
  "metrics": {
    "label_patterns": [
      { "label": "string", "pattern": "string" }
    ]
  }
}
```

- `config_schema` MUST be **Draft-4** JSON Schema (other drafts rejected).
- With a schema present, each named filter registers a subschema
  `proxy_wasm_filters/<name>`, and filter-chain `config` is validated against it and
  accepted as typed JSON.
- Without a schema, `config` MUST be a **string** (opaque bytes) and Kong does no
  validation. Invalid config only fails at the runtime (HTTP 500 on the proxied
  request).
- **Always ship a Draft-4 `config_schema`.** Pivot to runtime-safe rejection.
- Avoid Draft-4-unsupported keywords (`const`, `$ref` to external docs, `if/then/else`).
- Examples of `label_patterns`: `{ "label": "tenant_id", "pattern": "kong.*.tenant.*.id" }`
  (wires wasm-side `define_metric` labels to Kong metric extractors).

### 3.3 Kong's `proxy-wasm-rust-rate-limiting` reference (full meta.json)

```json
{
  "config_schema": {
    "type": "object",
    "properties": {
      "second": { "type": "integer" },
      "minute": { "type": "integer" },
      "limit_by": { "type": "string", "enum": ["ip","header","path"], "default": "ip" },
      "policy": { "type": "string", "enum": ["local"], "default": "local" }
    }
  }
}
```

Each plugin spec below defines its own `meta.json` extending this shape.

### 3.4 Filter-chain entity schema (decK / Kong DB entity)

Filter chains are managed via decK (`deck gateway sync`) through the Admin API to the
PostgreSQL-backed Kong instance (traditional mode). The schema:

```
filter_chains:
  name:            string
  enabled:         boolean (default true)
  filters:
    - name:    string        # matches .wasm filename in wasm_filters_path
      enabled: boolean        # per-filter toggle (default true)
      config:  string | object   # object only if matching meta.json has config_schema
```

A filter chain links 1:1 with a service or route (Kong 3.4+). Filters within a chain
execute in definition order; service-chain filters run before route-chain filters.
Multiple filter chains on different routes/services are permitted.

---

## 4. Phase Mapping in `ngx_wasm_module`

| Proxy-Wasm phase callback | Nginx phase | Yieldable | Can dispatch_http_call? |
|---------------------------|-------------|-----------|-------------------------|
| `on_http_request_headers` | access (rewrite+access) | yes | yes |
| `on_http_request_body`    | rewrite/access (continued) | yes | yes |
| `on_http_response_headers`| header_filter | **no** | **no** |
| `on_http_response_body`   | body_filter   | yes (buffered) | **no** in ngx_wasm_module |
| `on_http_call_response`   | (root context, async) | yes (always) | yes (nested allowed) |
| `on_http_call_trailers`   | trailer_filter | yes | bitrot-fragile; avoid |
| `on_log`                  | log_by_lua    | yes | yes (but cosocket-restricted in Lua; wasm has its own dispatch but `on_log` for wasm fires post-stream) |

**Lua plugins always run before Wasm filters** in every phase. If a Lua plugin
short-circuits (e.g. `kong.response.exit`), **no Wasm filters run** for that request.
Design plugin ordering to account for this : auth must not rely on downstream Wasm to
rescue a Lua-rejected request.

**Streaming body caveat:** `on_http_response_headers` is non-yieldable; you cannot
clear `Content-Length` there (it's already flushed). Header mutation must finish
before the first `body_filter` chunk. To mutate body size, **pause + buffer + resume**
is required (`Action::Pause` returns to host from `on_http_response_body`; host then
buffers and re-invokes with accumulated body until `end_of_stream=true`).

---

## 5. Hostcalls Available in `ngx_wasm_module`

Verified against `Kong/ngx_wasm_module` `docs/PROXY_WASM.md` (ABI v0.2.1):

### 5.1 Supported

| Category | Hostcalls |
|----------|-----------|
| Logging / time | `proxy_log`, `proxy_get_current_time_nanoseconds`, `proxy_set_effective_context` |
| Timers | `proxy_set_tick_period_milliseconds` |
| Buffers | `proxy_get_buffer_bytes`, `proxy_set_buffer_bytes` |
| Header maps | `proxy_get/set_header_map_pairs`, `proxy_get/set_header_map_value`, `proxy_add_header_map_value`, `proxy_replace_header_map_value`, `proxy_remove_header_map_value` |
| Properties | `proxy_get_property`, `proxy_set_property` |
| Streams | `proxy_continue_stream` (`resume_http_request`/`resume_http_response`) |
| Local response | `proxy_send_local_response` |
| HTTP dispatch | **`proxy_http_call`** : only outbound network primitive |
| Shared state | `proxy_get_shared_data` / `proxy_set_shared_data` (cross-worker; CAS-protected) |
| Shared queues | `proxy_register_shared_queue`, `proxy_enqueue_shared_queue`, `proxy_dequeue_shared_queue` |
| Metrics | `proxy_define_metric`, `proxy_get_metric`, `proxy_record_metric`, `proxy_increment_metric` |
| Foreign functions | `proxy_call_foreign_function` (used by `resolve_lua` for async DNS) |

### 5.2 NYI / unsupported in Kong host (must NOT rely on)

| Hostcall | Status |
|----------|--------|
| `proxy_get_log_level` | unsupported |
| `proxy_done` | unsupported |
| `proxy_close_stream` | unsupported |
| `proxy_resolve_shared_queue` | unsupported |
| `proxy_continue_response` | unsupported (cannot pause response except buffered body) |
| `proxy_resume_downstream` / `proxy_resume_upstream` | unsupported |
| **All gRPC dispatch** (`proxy_grpc_call`, `proxy_grpc_stream`, `proxy_grpc_send`, `proxy_grpc_cancel`, `proxy_grpc_close`, `proxy_get_status`) | unsupported |

**Implication for plugins:** LDAP/LDAP/OIDC/CACHE/FAILOVER must use `dispatch_http_call`
(plain HTTP), NOT gRPC. Validate all JWT bodies in guest; never dispatch gRPC for token
introspection (gRPC is widely assumed by Envoy examples but unavailable here).

---

## 6. `dispatch_http_call` Contract (Critical)

### 6.1 Signature

```rust
fn dispatch_http_call(
    &self,
    upstream: &str,                              // host (or host:port), NOT an Envoy cluster name
    headers: Vec<(&str, &str)>,                   // MUST include :method, :path, :authority
    body: Option<&[u8]>,
    trailers: Vec<(&str, &str)>,
    timeout: Duration,
) -> Result<u32, Status>;                         // returns token id
```

### 6.2 ngx_wasm_module specifics

- `upstream` arg is a **hostname/IP with optional `:port`**, resolved via nginx `resolver`
  or `proxy_wasm_lua_resolver` directive. NOT an Envoy cluster name
 (`Kong/ngx_wasm_module` Discussion #564 confirmed).
- Pseudo-headers in `headers` vec: `:method`, `:path`, **`:authority`** (NOT `:host`).
  Wrong pseudo-header → `BadArgument` (proxy-wasm SDK issue #172).
- Allowed from: `on_http_request_headers`, `on_http_request_body`, `on_tick`,
  `on_http_call_response` (nested dispatch).
- **Forbidden from:** `on_http_response_headers` (non-yieldable). Limited to buffered
  body in `on_http_response_body`.
- On dispatch failure, `on_http_call_response` fires with all size args 0 AND a synthetic
  `:dispatch_status` pseudo-header in the response headers map: `"timeout"`,
  `"broken connection"`, `"tls handshake failure"`, `"resolver failure"`,
  `"reader failure"`. Filters MUST inspect this and fail usefully (e.g. 503 with
  `Retry-After`, never silent 200).

### 6.3 Pause → Dispatch → Resume pattern (canonical)

```rust
impl HttpContext for MyFilter {
    fn on_http_request_headers(&mut self, _: usize, _: bool) -> Action {
        let body = /* build sidecar request */;
        match self.dispatch_http_call(
            "ldap-bridge.svc:8080",
            vec![(":method","POST"), (":path","/ldap/bind"),
                 (":authority","ldap-bridge.svc"), ("content-type","application/json")],
            Some(&body), vec![], Duration::from_millis(1500),
        ) {
            Ok(_token) => Action::Pause,        // hold downstream; wait for callback
            Err(Status::BadArgument) => {
                self.send_http_response(500, vec![], Some(b"bridge misconfig\n"));
                Action::Pause
            }
            Err(_) => {
                self.send_http_response(503, vec![("retry-after","2")], Some(b"unreachable\n"));
                Action::Pause
            }
        }
    }
}
impl Context for MyFilter {
    fn on_http_call_response(&mut self, _t: u32, nh: usize, bs: usize, _: usize) {
        if nh == 0 && bs == 0 {
            self.send_http_response(503, vec![], Some(b"timeout\n"));
            return;
        }
        /* parse response, inject headers, resume_http_request or send_http_response */
        self.resume_http_request();
    }
}
```

**Pitfalls proven by SDK issues (must handle):**
1. **`on_http_call_response` fires on the ROOT context** when dispatched from `on_tick`
   (background refresh), on the originating `HttpContext` when dispatched from a request
   callback (proxy-wasm-cpp-sdk #188). Use `set_effective_context(http_context_id)` to
   resume stream-scoped hostcalls from root context.
2. **Nested borrows** can BorrowMutError-panic if you `resume_http_request` after mutating
   a struct field after the call (issue #43). Do bookkeeping BEFORE the resume.
3. **`Action::Pause` only valid** in `on_http_request_headers`, `on_http_request_body`,
   `on_http_response_body` (buffering only), `on_http_call_response`. Cannot pause in
   response-header phase.
4. **Reentrancy**: a second `dispatch_http_call` from within `on_http_call_response`
   requires a `Response::{None,First,Second}` state field per filter (issue #40).
5. **Timeout detection** (SDK PR #296): `on_http_call_response` with `num_headers==0
   && body_size==0` ⇒ the host's per-hostcall timeout expired. Treat as infra failure,
   never as a silent 200.

---

## 7. State Model

### 7.1 Per-request state → struct fields on `HttpContext` impl

Simplest and safest. `HttpContext` is constructed once per stream; the same `&mut self`
flows through request and response callbacks. Store the per-stream PII maps,
pending tokens, parsed claims, decoded request bodies, etc. here.

```rust
struct MyFilter {
    config: Config,                  // cloned at create_http_context
    pending_token: Option<u32>,
    parsed_claims: Option<Claims>,
    request_body_buffer: Vec<u8>,
}
impl HttpContext for MyFilter { /* ... */ }
```

### 7.2 Cross-callback (within one context) state → `wasmx.*` properties

`set_property(vec!["wasmx","mykey"], Some(&bytes))` / `get_property(...)`.
The `wasmx.*` namespace is context-scoped : Root-scope writes invisible from HTTP
context and vice versa. Useful for callbacks within the same context that span multiple
host-call exchanges (e.g. JWKS cache update on the root context).

### 7.3 Cross-request / cross-worker state → `get_shared_data` / `set_shared_data`

SHM zone declared via nginx directive `wasm_shm_kv` (env var
`KONG_NGINX_WASM_SHM_<ZONE_NAME>=<size>`). CAS-protected atomic updates:

```rust
match self.set_shared_data(key, Some(&bytes), Some(cas_token)) {
    Ok(()) => /* saved */,
    Err(Status::CasMismatch) => /* re-read value+cas from get_shared_data, retry */,
    Err(_) => /* SDK panics on other errors */,
}
```

Standard retry loop pattern (from Kong's `proxy-wasm-rust-rate-limiting`):
up to 10 retries, on exhausted return an explicit error (never silent).

```rust
let mut saved = false;
for _ in 0..10 {
    let buf = new_val.to_le_bytes();
    match self.set_shared_data(&key, Some(&buf), cas) {
        Ok(()) => { saved = true; break; }
        Err(Status::CasMismatch) => {
            let (nv, nc) = self.get_shared_data(&key); // (Some(bytes), Some(cas))
            if let (Some(b), Some(c)) = (nv, nc) {
                new_val = i32::from_le_bytes(b.try_into().unwrap());
                cas = c;
            }
        }
        Err(_) => { /* log + break */ }
    }
}
if !saved { log::error!("could not save state for key {}", key); }
```

### 7.4 No `kong.*` / `ngx.ctx` access from Wasm

**Confirmed:** the `kong.*` property namespace used by Kong's own rate-limiting showcase
filter returns empty in real Kong : it was aspirational; the showcase README lists
"Getting proper route and service ids" under *What's missing*. The `kong.ctx` PDK API is
**Lua-only**; Kong's wasm reference states Wasm filters have **no access to Kong's Lua PDK**.
The `ngx.*` property namespace maps to **nginx variables** (`ngx.var`), not OpenResty's
`ngx.ctx` table. Most nginx variables are immutable; `set_property(ngx.*)` on an immutable
var **traps** (wasm trap). Only `request.query` (mapped to `ngx.args`) is documented
writable among Envoy attributes.

**Identity propagation:** auth plugins MUST use `set_http_request_header("x-tenant-id",
Some(value))` : these become visible in `ngx.req.get_header()` and `kong.service.request
.get_header()` upstream. NOT `set_property`.

---

## 8. Cross-Filter Identity Propagation Contract

All four custom plugins share this canonical header set, injected by the auth filter and
read by all downstream plugins:

| Header | Source (auth plugin) | Read by | Required in every request? |
|--------|---------------------|---------|----------------------------|
| `X-Tenant-ID` | tenant claim / AD attribute | cache, failover, telemetry | yes |
| `X-User-ID` | OIDC `sub` / AD `sAMAccountName` | failover (LB key), telemetry | yes |
| `X-Routing-Tier` | group claim / AD group mapping | cache (filter), failover (LB) | yes |
| `X-Token-Scopes` | `scope`/`scp` claim | failover (RBAC), audit | optional |

**Auth filter MUST strip raw `Authorization` header** before forwarding upstream
(unless an explicit `keep_authorization` per-route config opt-in is set), via
`remove_http_request_header("authorization")`. This prevents credential leakage to LLM
providers.

**Failover/cache/telemetry plugins MUST NOT trust** these headers from the inbound
client : only trust them after the auth filter has run (filter-chain order: auth first).
A SAFEDRAFT: also verify there is no `X-Tenant-ID` header pre-existing on inbound before
auth runs (prevent spoofing; auth overwrites or rejects).

---

## 9. Error Handling Discipline

Per AGENTS.md Rule 13: **no silent error swallowing, no silent fallbacks**.

For every filter:

| Outcome | Behavior |
|---------|----------|
| Infra failure (sidecar down, timeout, parse error of sidecar data) | Log + emit `X-Auth-Error`/`X-Cache-Error`/`X-Failover-Error` response header + return 503 (auth) or fall through to upstream (cache). **Never** silently 200. **Never** silently `Continue`. |
| Auth denial (bad token, expired, wrong audience) | 401/403 with RFC 6750 `WWW-Authenticate: Bearer realm="..."` error attributes. |
| Internal filter bug (wasm panic) | `panic = "abort"` traps the instance; the host aborts the request (typically 500 from the proxy). Prefer explicit `Err` propagation; no `unwrap()` on hostcalls except where SDK guarantees success. |
| Config parse failure (`on_configure` returns false) | Filter disabled at startup; logged. No runtime failover attempted at the filter level (Kong route must have a backup plan). |

---

## 10. Operational Conventions

- **One Wasm module per plugin**, one filter per route's filter chain.
- **OTP-style plugin guarding:** each plugin documents its own `meta.json` `config_schema`;
  Kong Admin API rejects invalid config at apply time (return 400), not at request time.
- **Version pinning in decK:** explicit `min_version` field in filter `config` for forward
  compatibility assertions, per-plugin. Config is synced via `deck gateway sync` through
  the Admin API to PostgreSQL (traditional mode).
- **Sidecar deployment:** sidecars (embedding, cache shim, LDAP bridge, NER) run as
  systemd user binaries on the same host, reachable from Kong via the nginx `resolver`.
  mTLS on the bridge leg; secrets (keytabs, OpenAI keys) live on the sidecar, never in
  the Wasm module.

---

## 11. References (shared)

- Kong `meta.json`/filter schema: https://docs.konghq.com/gateway/latest/plugin-development/wasm/filter-configuration/
- Kong wasm reference: https://docs.konghq.com/gateway/latest/reference/wasm/
- Kong showcase `proxy-wasm-rust-rate-limiting` (Cargo.toml, src/filter.rs, .cargo/config.toml, meta.json): https://github.com/Kong/proxy-wasm-rust-rate-limiting
- `Kong/kong` `kong/runloop/wasm.lua` `FILTER_META_SCHEMA`: https://github.com/Kong/kong/blob/58f2daa5/kong/runloop/wasm.lua
- `Kong/ngx_wasm_module` `docs/PROXY_WASM.md`: https://github.com/Kong/ngx_wasm_module/blob/main/docs/PROXY_WASM.md
- `Kong/ngx_wasm_module` `docs/DIRECTIVES.md` (shm_kv zones): https://github.com/Kong/ngx_wasm_module/blob/main/docs/DIRECTIVES.md
- Proxy-Wasm Rust SDK v0.2.5: https://crates.io/crates/proxy-wasm
- SDK traits reference: https://docs.rs/proxy-wasm/0.2/proxy_wasm/traits/index.html
- SDK hostcalls reference: https://docs.rs/proxy-wasm/0.2/proxy_wasm/hostcalls/index.html
- `dispatch_http_call` async + `:authority` trap (issue #172): https://github.com/proxy-wasm/proxy-wasm-rust-sdk/issues/172
- Pause/Resume/Promise pattern (PR #265): https://github.com/proxy-wasm/proxy-wasm-rust-sdk/pull/265
- `wasm32-wasi` → `wasm32-wasip1` rename (Rust 1.84): https://blog.rust-lang.org/2024/11/19/Rust-1.84.0.html
- `serde-json-wasm` (no_std JSON): https://crates.io/crates/serde-json-wasm

---

## 12. Per-Plugin Doc Index

The four per-plugin specs that inherit this foundation:

| Document | Plugin | Language | Replaces |
|----------|--------|----------|---------|
| `PLUGIN-REDACT.md` | inline PII anonymization + re-hydration | **Lua** (Kong plugin) | none : replaces the v1.0 Rust-Wasm anonymizer |
| `PLUGIN-AUTH-OIDC.md` | OIDC / OAuth2 JWT bearer validation | Rust Proxy-Wasm | Kong `openid-connect` (Enterprise) |
| `PLUGIN-AUTH-LDAP.md` | legacy AD via LDAP/Kerberos HTTP bridge | Rust Proxy-Wasm + sidecar | Kong `ldap-auth-advanced` (Enterprise) |
| `PLUGIN-SEMANTIC-CACHE.md` | Redis VSS semantic cache | Rust Proxy-Wasm + sidecar | Kong `ai-semantic-cache` (Enterprise) |
| `PLUGIN-FAILOVER.md` | multi-provider weighted LB + adaptive failover | Rust Proxy-Wasm + Lua helper | Kong `ai-proxy-advanced` (Enterprise) |

See `README.md` in this directory for the directory index.

**End of document.**