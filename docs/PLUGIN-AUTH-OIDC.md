# Plugin Spec: Auth OIDC - Stateless JWT Validation Proxy-Wasm Filter

**Document ID:** AMI-PROP-LLMGW-PLUGIN-AUTH-OIDC-v1.0
**Status:** Draft
**Date:** 2026-07-04
**Parent:** `PROPOSAL-LLM-GATEWAY-v2.md`; inherits `PLUGIN-FOUNDATION.md`
**Replaces:** Kong Enterprise `openid-connect` plugin (`tier: enterprise`)
**Reference implementation to fork:** `systemshardening` zero-trust wasm JWT validator

This document specifies the custom Rust Proxy-Wasm filter that validates OIDC/OAuth2
bearer JWTs against cached JWKS, with multi-issuer (Keycloak + Entra ID) support, claim
verification per OIDC Core / RFC 7519 / RFC 6750, and injection of the Unified Context
headers (`X-Tenant-ID`, `X-User-ID`, `X-Routing-Tier`).

---

## 1. Architecture

```
                Rust Proxy-Wasm filter (auth-oidc)
request -->  on_http_request_headers (access phase)
             |
             +-- if no Authorization: 401 + WWW-Authenticate: Bearer
             |   (no error attr per RFC 6750 when creds merely omitted)
             |
             +-- decode JWT (base64url header + claims + signature)
             |   -- failure (malformed / wrong alg / alg=none) -> 401 invalid_token
             |
             +-- lookup kid in cached JWKS (shared_data per tenant)
             |   -- if miss: dispatch_http_call refresh to IdP jwks_uri, Action::Pause
             |       on_http_call_response: cache new JWKS (CAS), retry once via ResumeHttpRequest
             |       -- if refresh already in flight: queue / 401 key_material_unavailable
             |
             +-- verify signature (RS256 / ES256 / EdDSA) using RustCrypto crates
             |   -- signature fails -> 401 invalid_token
             |
             +-- validate claims: iss, aud, exp, nbf (with leeway)
             |   -- failure: 401 invalid_token / 403 insufficient_scope
             |
             +-- inject Unified Context headers via set_http_request_header
             +-- remove Authorization header before upstream egress
             +-- Action::Continue
```

JWKS fetched async via `dispatch_http_call` and cached in shared_data with TTL from
IdP `Cache-Control`. Refresh driven by `on_tick` (default 3600s) plus on-demand refresh
on `kid` miss (`Action::Pause` then resume after refresh).

---

## 2. Overview of Constraints Inherited

From `PLUGIN-FOUNDATION.md`:
- `proxy-wasm = "0.2.5"` (NOT 0.3.0-dev).
- Target `wasm32-wasip1` (Rust 1.84+).
- Core-wasm module, NOT component.
- Kong host: gRPC is NYI; use `dispatch_http_call` only.
- No `kong.*` property namespace; use `set_http_request_header` for identity injection.
- `panic = "abort"`; explicit error propagation, no `unwrap()` on hostcalls.
- meta.json `config_schema` MUST be JSON Schema Draft-4.

---

## 3. Validation Stack (Rust Crate Matrix)

| Crate | wasm32-wasip1 | Use |
|-------|--------------|-----|
| `ring` / `aws-lc-rs` | **NO** (needs C/clang) | do NOT use |
| `rsa` (RustCrypto) | **YES** | RS256 / RS384 : pure Rust |
| `p256` / `p384` (RustCrypto) | **YES** | ES256 / ES384 |
| `ed25519-dalek` | **YES** | EdDSA (Ed25519) : verifying path needs no RNG |
| `sha2` / `hmac` | **YES** | hash primitives |
| `base64` with `URL_SAFE_NO_PAD` | **YES** | JWT segments |
| `serde` / `serde_json` | **YES BUT avoid `serde_json` - use `serde-json-wasm`** | parse JWT header/claims |
| `getrandom` | **YES** on wasm32-wasip1 (native `__wasi_random_get`) | RNG for ED path; not needed for verify-only |
| `biscuit` / `jsonwebtoken` | **MAYBE** (`jsonwebtoken` v10 with `default-features=false, features=["rust_crypto"]`) | optional convenience; prefer manual decode-verify for fine control |

**Recommended stack:**
```toml
[dependencies]
proxy-wasm = "0.2"
serde = { version = "1", features = ["derive"] }
serde-json-wasm = "0.5"
base64 = "0.22"
sha2 = "0.10"
hmac = "0.12"
rsa = "0.9"
p256 = { version = "0.13", features = ["ecdsa"] }
p384 = { version = "0.13", features = ["ecdsa"] }
ed25519-dalek = { version = "2", features = ["pkcs8", "pem"] }
hex = "0.4"
log = "0.4"
```

**Algorithms supported:** RS256, RS384, ES256, ES384, EdDSA (Ed25519). HS256 supported
only when a symmetric secret is also configured locally (avoid for IdP-issued tokens).
`alg=none` REJECTED unconditionally (no unauthenticated JWT).

---

## 4. `meta.json` `config_schema`

```json
{
  "config_schema": {
    "type": "object",
    "properties": {
      "issuers": {
        "type": "array",
        "minItems": 1,
        "items": {
          "type": "object",
          "properties": {
            "tenant_id"  : { "type": "string", "pattern": "^[a-zA-Z0-9_.-]+$" },
            "issuer"     : { "type": "string", "format": "uri" },
            "jwks_uri"   : { "type": "string", "format": "uri" },
            "jwks_cluster": { "type": "string", "description": "ip or host:port reachable by dispatch_http_call" },
            "audience"   : { "type": "string" },
            "scopes_required": { "type": "array", "items": { "type": "string" } },
            "groups_claim" : { "type": "string", "default": "groups" },
            "tenant_claim" : { "type": "string", "default": "tenant_id" },
            "user_claim"    : { "type": "string", "default": "sub" }
          },
          "required": ["tenant_id", "issuer", "jwks_uri", "jwks_cluster", "audience"]
        }
      },
      "leeway_seconds":    { "type": "integer", "default": 60 },
      "jwks_ttl_seconds":  { "type": "integer", "default": 3600 },
      "allow_refresh_on_kid_miss": { "type": "boolean", "default": true },
      "strip_authorization": { "type": "boolean", "default": true },
      "fail_open":         { "type": "boolean", "default": false }
    },
    "required": ["issuers"]
  }
}
```

**Discriminator pattern:** tenant is resolved from request context : either `Host`
header, path prefix matching, or an upstream-injected bootstrap `X-Tenant-Bootstrap`
header. The filter looks up the matching `config.issuers[i]` (by `tenant_id`) and uses
that entry's `issuer`, `jwks_uri` etc. for this request.

---

## 5. Crate Structure

```
auth-oidc-filter/
  .cargo/config.toml                       # target = wasm32-wasip1
  Cargo.toml
  auth_oidc_filter.meta.json                # config_schema above
  src/
    lib.rs                                  # proxy_wasm::main! + RootContext/HttpContext impls
    config.rs                               # deserialize config via serde-json-wasm
    jwt.rs                                  # decode header+claims+signing_input+signature
    jwks.rs                                 # JWKS struct, find_kid, parse from HTTP body
    verify/
      mod.rs                                # verify(alg, jwk, signing_input, sig) -> Result<()>
      rsa.rs                                # RS256/RS384 via rsa crate
      ecdsa.rs                              # ES256/ES384 via p256/p384
      eddsa.rs                              # EdDSA via ed25519-dalek
    context.rs                              # inject X-Tenant-ID / X-User-ID / X-Routing-Tier
    error.rs                                # error enum, RFC 6750 error codes
```

---

## 6. Lifecycle Implementation

### 6.1 `RootContext` (JWKS cache ownership)

```rust
struct AuthRoot {
    config: Config,
    jwks_cache: HashMap<TenantId, Jwks>,    // in-memory copy per worker's VM
    jwks_cas: HashMap<TenantId, u32>,        // shared_data CAS tokens
}

impl RootContext for AuthRoot {
    fn get_type(&self) -> Option<ContextType> { Some(ContextType::HttpContext) }

    fn on_vm_start(&mut self, _: usize) -> bool {
        // Kick off initial JWKS fetches per tenant (one dispatch per issuer).
        for issuer in &self.config.issuers {
            let _ = self.dispatch_http_call(
                &issuer.jwks_cluster,
                vec![(":method","GET"),
                     (":path", issue_jwks_path(&issuer.jwks_uri)),
                     (":authority", &issuer.jwks_cluster)],
                None, vec![], Duration::from_secs(5),
            );
        }
        self.set_tick_period(Duration::from_secs(self.config.jwks_ttl_seconds as u64));
        true
    }

    fn on_configure(&mut self, _: usize) -> bool {
        let cfg = match self.get_plugin_configuration() {
            Some(b) => b,
            None => return false,
        };
        match serde_json_wasm::from_slice::<Config>(&cfg) {
            Ok(c) => { self.config = c; true }
            Err(e) => { log::error!("auth-oidc config parse failed: {}", e); false }
        }
    }

    fn on_tick(&mut self) {
        // Background refresh: re-fetch all JWKS per tenant. on_http_call_response runs on ROOT.
        for issuer in &self.config.issuers {
            let _ = self.dispatch_http_call(/* ... as on_vm_start ... */);
        }
    }

    fn create_http_context(&self, _: u32) -> Option<Box<dyn HttpContext>> {
        Some(Box::new(AuthHttp {
            root_config: self.config.clone(),
            pending_token: None,
            pending_request_tenant: None,
        }))
    }
}

impl Context for AuthRoot {
    fn on_http_call_response(&mut self, _t: u32, _nh: usize, bs: usize, _nt: usize) {
        // ROOT context callback for refresh dispatches.
        if bs == 0 { return; }       // timeout / failure: keep old JWKS; do nothing
        if let Some(body) = self.get_http_call_response_body(0, bs) {
            if let Ok(jwks) = serde_json_wasm::from_slice::<Jwks>(&body) {
                // store with CAS for cross-worker: write shared_data, then mirror in root cache.
                let key = format!("jwks:{}", /* tenant */);
                let raw = body.clone();
                let _ = self.set_shared_data(&key, Some(&raw), None);
                self.jwks_cache.insert(/* tenant */, jwks);
            }
        }
    }
}
```

### 6.2 `HttpContext`

```rust
struct AuthHttp {
    root_config: Config,
    pending_token: Option<u32>,
    pending_request_tenant: Option<TenantId>,
    decoded_header: Option<JwtHeader>,
    decoded_claims: Option<JwtClaims>,
    signing_input: Option<Vec<u8>>,
    signature: Option<Vec<u8>>,
}

impl HttpContext for AuthHttp {
    fn on_http_request_headers(&mut self, _: usize, _: bool) -> Action {
        // 1. Resolve tenant from request context.
        let tenant = match self.resolve_tenant() {
            Ok(t)  => t,
            Err(e) => return self.reject_401(&e, /* no_token */ false),
        };
        let issuer = match self.root_config.issuers.iter().find(|i| i.tenant_id == tenant) {
            Some(i) => i,
            None    => return self.reject_400("unknown_tenant"),
        };
        // 2. Extract bearer.
        let token = match self.bearer_token() {
            Ok(t)  => t,
            Err(_) => return self.reject_401("missing_or_invalid_auth_header", true),
        };
        // 3. Decode.
        let (hdr, claims, input, sig) = match decode_jwt(token) {
            Ok(x)  => x,
            Err(e) => return self.reject_401(&format!("malformed_token: {e}"), false),
        };
        // 4. Reject alg=none / unsupported.
        if hdr.alg.eq_ignore_ascii_case("none") || !SUPPORTED_ALGS.contains(&hdr.alg.as_str()) {
            return self.reject_401("unsupported_algorithm", false);
        }
        // 5. JWKS lookup.
        let jwks = match self.lookup_jwks(&tenant) {
            Some(k) => k,
            None if self.root_config.allow_refresh_on_kid_miss => {
                return self.trigger_jwks_refresh_and_pause(&tenant);
            }
            None => return self.reject_401("key_material_unavailable", false),
        };
        // 6. Find kid.
        let jwk = match hdr.kid.as_ref().and_then(|k| jwks.find_kid(k)) {
            Some(j) => j,
            None if self.root_config.allow_refresh_on_kid_miss => {
                self.pending_token = None; self.pending_request_tenant = Some(tenant);
                return self.trigger_jwks_refresh_and_pause(&tenant);
            }
            None => return self.reject_401("unknown_kid", false),
        };
        // 7. Verify signature.
        if let Err(e) = verify(&hdr.alg, jwk, &input, &sig) {
            return self.reject_401(&format!("signature_failed: {e}"), false);
        }
        // 8. Validate claims (iss/aud/exp/nbf with leeway; scopes).
        if let Err(e) = self.validate_claims(&claims, issuer) {
            return self.reject_with_claims_error(&e);
        }
        // 9. Inject Unified Context headers + strip Authorization.
        self.inject_context(&claims, issuer);
        if self.root_config.strip_authorization {
            self.remove_http_request_header("authorization");
        }
        Action::Continue
    }
}

impl Context for AuthHttp {
    fn on_http_call_response(&mut self, token: u32, _nh: usize, bs: usize, _nt: usize) {
        // Same callback as Root, but now we're resuming a paused request.
        if bs == 0 {
            self.send_http_response(401, vec![("WWW-Authenticate","Bearer realm=\"...\", error=\"invalid_token\", error_description=\"jwks_refresh_timeout\"")], Some(b"JWKS refresh timeout\n"));
            return;
        }
        let body = self.get_http_call_response_body(0, bs).unwrap_or_default();
        if let Ok(jwks) = serde_json_wasm::from_slice::<Jwks>(&body) {
            if let Some(tenant) = self.pending_request_tenant.take() {
                let key = format!("jwks:{}", tenant);
                let _ = self.set_shared_data(&key, Some(&body), None);
                // Re-validate the pending request: refresh was successful, retry the validation.
                if let Some((hdr, claims, input, sig)) = self.pending_decoded.take() {
                    if let Some(jwk) = hdr.kid.as_ref().and_then(|k| jwks.find_kid(k)) {
                        if verify(&hdr.alg, jwk, &input, &sig).is_ok() {
                            if self.validate_claims(&claims, /*issuer*/).is_ok() {
                                self.inject_context(&claims, /*issuer*/);
                                self.resume_http_request();
                                return;
                            }
                        }
                    }
                }
            }
        }
        // Could not validate post-refresh: fail closed.
        self.send_http_response(401, vec![("WWW-Authenticate","Bearer realm=\"...\", error=\"invalid_token\"")], Some(b"invalid token\n"));
    }
}
```

---

## 7. Claim Validation Spec

Per OIDC Discovery 1.0 / RFC 7519:

| Claim | Validation | Error |
|-------|------------|-------|
| `iss` | MUST match `issuer` for the resolved tenant's issuer entry | `invalid_token`, 401 |
| `aud` | MUST contain `audience` (accept string OR array) | `insufficient_scope`, 403 (aud is authorization, not authn; many gateways 401 : we choose 403 when token otherwise valid but lacks this resource's audience per RFC 6750 §3.1) |
| `exp` | `now > exp + leeway_seconds` → reject | `invalid_token`, 401 |
| `nbf` | `now < nbf - leeway_seconds` → reject | `invalid_token`, 401 |
| `iat` | `iat > now + leeway_seconds` → reject | `invalid_token`, 401 |
| `scope`/`scp` | MUST contain all entries in `scopes_required` per issuer entry | `insufficient_scope`, 403 |
| `groups` | Read; first match against tier mapping rule + emit `X-Routing-Tier` | (no rejection : at least one group required if `require_group: true` per issuer) |

**Leeway** default 60s : configurable. All time comparisons use `Context::get_current_time()`
hostcall (epoch nanoseconds) : NOT `SystemTime::now()` in the guest (which may be undefined
on non-wasip1 targets).

---

## 8. Unified Context Injection Contract

On success, the filter does (per `PLUGIN-FOUNDATION.md` Section 8):

```rust
self.set_http_request_header("x-tenant-id", Some(&claims.tenant_id));
self.set_http_request_header("x-user-id", Some(&claims.sub));
self.set_http_request_header("x-routing-tier", Some(&routing_tier));
self.set_http_request_header("x-token-scopes", Some(&claims.scope_joined));
self.set_http_request_header("x-token-issuer", Some(&claims.iss));
if config.strip_authorization { self.remove_http_request_header("authorization"); }
```

These headers are visible to downstream Lua plugins (via `kong.service.request.get_header`)
and to upstream Wasm filters (via `get_http_request_header` in their own
`on_http_request_headers`).

---

## 9. Failure Modes (RFC 6750 Conformant)

All failures **fail closed**. Per RFC 6750 §3, `WWW-Authenticate: Bearer realm="..."`
with error attributes is emitted on 401 when a token was presented.

| Failure | HTTP | Body / `WWW-Authenticate` |
|--------|------|------------------------------|
| No `Authorization` header / not `Bearer ` | 401 | `WWW-Authenticate: Bearer realm="<tenant>"` (no error per RFC: "SHOULD NOT include error code" when no creds) |
| Malformed JWT (<3 parts, bad b64, bad header JSON) | 401 | `error="invalid_token", error_description="malformed token"` |
| `alg=none` / unsupported `alg` | 401 | `error="invalid_token", error_description="unsupported algorithm"` |
| `kid` not in cached JWKS (after refresh attempt) | 401 | `error="invalid_token", error_description="unknown kid"` |
| Signature invalid | 401 | `error="invalid_token", error_description="signature verification failed"` |
| `exp` past | 401 | `error="invalid_token", error_description="the access token expired"` |
| `nbf` future | 401 | `error="invalid_token", error_description="token not yet valid"` |
| `iss` mismatch | 401 | `error="invalid_token", error_description="issuer mismatch"` |
| `aud` mismatch (otherwise valid token) | 403 | `error="insufficient_scope"` (per §3.1) |
| Missing required scope/group | 403 | `WWW-Authenticate: Bearer realm="...", error="insufficient_scope", scope="<needed>"` |
| JWKS not loaded (cold start, fail_open=false) | 401 | `error="invalid_token", error_description="key material unavailable"`. (Optionally 503 if you want retryable; prefer fail-closed 401 to avoid silent bypass.) |
| JWKS refresh timed out (kid-miss path) | 401 | `invalid_token", error_description="jwks_refresh_timeout"` |
| Tenant unresolved (no mapping) | 400 | `error="invalid_request", error_description="unknown tenant"` |
| Filter config parse failure (at startup) | : | Filter disabled; logged at startup. No runtime failover attempted at filter level : Kong route must have a backup plan (e.g. deny by default). |

`fail_open: false` is the production default (per AGENTS.md Rule 13). When `fail_open: true`
(a deliberate degraded-mode opt-in for low-stakes dev tenants), the filter surfaces
`X-Auth-Error: key_material_unavailable` and `Action::Continue` : but this setting is
documented as "DO NOT use in prod" and emits a `WARN` log on every continue.

---

## 10. State Model

- JWKS cached per tenant in `shared_data` (`jwks:<tenant_id>` key) : cross-worker,
  CAS-protected, refreshed on `on_tick` (default 3600s) and on kid-miss.
- A root-local mirror of the JWKS struct in `AuthRoot::jwks_cache` for performance :
  avoids re-deserializing from shared_data bytes on every request.
- Per-request decoded state lives in `AuthHttp` struct fields (header, claims, signing
  input, signature, pending token) : request-scoped, no leaking.
- No PII or token leakage: the raw JWT is decoded once into the struct fields; never
  logged. `tracing`/`log` calls carry only the kid, alg, iss (no token body).

---

## 11. Threading / Concurrency

- One VM per nginx worker (default; can be 1 VM shared across workers with
  `proxy_wasm_isolation none`).
- Shared_data SHM zone is cross-worker (the nginx shm_kv zone). JWKS writes via CAS
  are atomic across workers.
- `on_http_call_response` for `on_tick`-initiated refreshes runs on ROOT context :
  use the root's `set_shared_data` (valid since root is a `Context`).
- `on_http_call_response` for kid-miss refreshes runs on the originating `HttpContext`
  : filter MUST call `set_effective_context(http_context_id)` before mutating
  request headers/resuming (per proxy-wasm-cpp-sdk #188).

---

## 12. Test Plan (Required)

- Unit: `decode_jwt` with valid 3-segment tokens, malformed inputs (2-seg, 4-seg, bad
  base64, JSON parse failure).
- Unit: `verify` per algorithm : RS256, RS384, ES256, ES384, EdDSA : using test vectors
  with known keys + signatures. Reject `alg=none`. Reject alg-confusion (e.g. token
  signed with HS256 but presenting as RS256).
- Unit: `validate_claims` : exp past/future, nbf future, audience scalar/array, scopes
  required missing/present.
- Unit: JWKS parse : known OpenID `/.well-known/openid-configuration` mock + JWKS JSON
  with RSA, EC, OKP keys; `find_kid` returns correct JWK.
- Integration: end-to-end with mock IdP returning a valid JWKS : assert context headers
  injected, Authorization stripped, request proceeds.
- Integration: JWKS kid-miss triggers refresh → second lookup succeeds → request
  proceeds. Mock refresh failure → 401 with `key_material_unavailable`.
- Integration: token signed with `alg=none` → 401 unsupported_algorithm (never bypass).
- Integration: expired token → 401 invalid_token with `WWW-Authenticate`.
- Integration: no `Authorization` header → 401 with `WWW-Authenticate` realm challenge
  but NO `error=` attribute (per RFC 6750 §3).
- Multi-tenant: requests with different `Host` / `X-Tenant-Bootstrap` resolve to
  different issuers; wrong tenant's token rejected via iss mismatch.
- Concurrency: parallel requests + concurrent JWKS refresh : assert CAS retry loop
  works, no race.

---

## 13. Reference Implementations to Adapt

| Repo | Fit |
|------|-----|
| `systemshardening.com` wasm JWT validator (https://www.systemshardening.com/articles/wasm/wasm-edge-zero-trust-auth/) | **Best skeleton** : extend with EdDSA/OKP, kid-miss refresh, multi-tenant map, RFC 6750 error bodies |
| `RamazanKara/proxy-wasm-jwt-validator` | closest off-the-shelf HS256+RS256 bearer validator; adapt for `dispatch_http_call` JWKS + EC/Ed support |
| `tgunsch/envoy-filter-claim-to-header` | minimal claim→header injection reference |
| Istio/Envoy native `jwt_authn` (C++) | behavioral reference, not code |

**Recommended v1 path:** Clone systemshardening example → add (a) `ed25519-dalek` for
EdDSA, (b) kid-miss `Action::Pause` refresh path, (c) tenant→issuer/jwks-cluster map
from plugin config, (d) RFC 6750-grade `WWW-Authenticate` error responses, (e)
`set_shared_data` CAS-based JWKS cache keyed by tenant.

---

## 14. Open Questions

| Q | Resolution |
|---|------------|
| Tenant discriminator choice (Host header vs path prefix vs bootstrap header) | v1 supports all three via a config `tenant_resolver` field; default `host` |
| Multi-tenancy at one filter instance vs one filter per route | Spec supports both; recommended one filter per route for simplicity |
| JWKS refresh-storm prevention | Single-flight: if a refresh is in flight for a tenant, queue kid-miss requests instead of triggering N parallel refreshes |
| `fail_open` semantics | Default false (fail closed 401); `true` deliberately degraded-mode opt-in with WARN log per continue |
| WWW-Authenticate `realm="<tenant>"` format | Verbatim tenant_id, OR route host : to be finalized in the integration guide |

---

## 15. References

- OIDC Discovery 1.0: https://openid.net/specs/openid-connect-discovery-1_0-errata2.html
- RFC 7519 (JWT): https://datatracker.ietf.org/doc/html/rfc7519
- RFC 7517 (JWK): https://datatracker.ietf.org/doc/html/rfc7517
- RFC 6750 (Bearer token usage, WWW-Authenticate): https://www.rfc-editor.org/rfc/rfc6750.html
- Kong `openid-connect` plugin reference (for claim options to replicate): https://developer.konghq.com/plugins/openid-connect/reference/
- RustCrypto crates: https://github.com/RustCrypto
- `jsonwebtoken` v10 wasm support (PR #346): https://github.com/Keats/jsonwebtoken/pull/346
- `ed25519-dalek`: https://docs.rs/ed25519-dalek/
- `getrandom` wasi backend: https://docs.rs/getrandom/
- `proxy-wasm-rust-sdk` hostcalls: https://docs.rs/proxy-wasm/latest/proxy_wasm/hostcalls/
- `dispatch_http_call` semantics + `:authority` trap: https://github.com/proxy-wasm/proxy-wasm-rust-sdk/issues/172
- systemshardening reference filter: https://www.systemshardening.com/articles/wasm/wasm-edge-zero-trust-auth/
- `RamazanKara/proxy-wasm-jwt-validator`: https://github.com/RamazanKara/proxy-wasm-jwt-validator
- `tgunsch/envoy-filter-claim-to-header`: https://github.com/tgunsch/envoy-filter-claim-to-header
- Envoy native `jwt_authn` (behavioral spec): https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/jwt_authn_filter.html

---

**End of document.**