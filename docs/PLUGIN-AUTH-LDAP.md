# Plugin Spec: Auth LDAP - Legacy Active Directory via HTTP Bridge

**Document ID:** AMI-PROP-LLMGW-PLUGIN-AUTH-LDAP-v1.0  
**Status:** Draft  
**Date:** 2026-07-04  
**Parent:** `PROPOSAL-LLM-GATEWAY-v2.md`; inherits `PLUGIN-FOUNDATION.md`  
**Replaces:** Kong Enterprise `ldap-auth-advanced` plugin (`tier: enterprise`)

This document specifies the custom Rust Proxy-Wasm filter that authenticates legacy
Windows Active Directory users over LDAP (or Kerberos) by delegating the actual bind /
ticket-validation to an **HTTP bridge sidecar**. The Proxy-Wasm guest cannot open
TCP sockets (LDAP/Redis/Kerberos are all raw-TCP protocols); the only outbound
primitive is `dispatch_http_call`. The bridge is a small HTTP service wrapping LDAP /
Kerberos (libgssapi / MIT krb5 / pure-Rust `rskrb5`) reachable from the guest over
localhost. The guest uses the proven pause-dispatch-resume pattern; the bridge owns
the secrets (keytab, service-account DN/password) and never passes them to the guest.

---

## 1. Architecture

```
Rust Proxy-Wasm filter (auth-ldap)                   LDAP/Kerberos Bridge (sidecar)
+-----------------------------------------+          +-----------------------------------+
| on_http_request_headers (access)        |          |   Axum / small Go service         |
|   read Authorization                    |          |   holds: AD service-account creds |
|     - Basic: <user>:<password>          |  POST    |             keytab (Kerberos)     |
|     - Negotiate: <krb_ap_req base64>     |  -----> |   /ldap/bind  -> ldap-simple/     |
|   resolve tenant from request ctx       |          |                  bind+search     |
|   dispatch_http_call to bridge          |          |   /krb/validate -> krb5_rd_req +    |
|   Action::Pause                         |          |                  replay-cache     |
|                                         |  <-----  |                                   |
| on_http_call_response (root ctx)        |          | Response: 200 {success, user,    |
|   if 200: inject X-Tenant-ID,           |          |   groups, tenant, attributes}     |
|     X-User-ID, X-Routing-Tier            |          |        401 credentials rejected  |
|     resume_http_request                 |          |        503 AD unreachable         |
|   if 401/503: send_http_response        |          |                                   |
+-----------------------------------------+          +-----------------------------------+
                          |
                          v (mTLS on private cluster, or localhost in-pod)
                     [ AD Domain Controller pool (LDAP/389, LDAPS/636, Kerberos/88) ]
```

---

## 2. The No-Socket Constraint (Inherited)

From Proxy-Wasm spec v0.2.1 and the Rust SDK hostcall inventory: the only outbound
network hostcalls are `proxy_http_call` and `proxy_grpc_call`. There is no socket
syscall in the wasm guest. ldap-py / native `ldap-rs` / MIT krb5 all need raw TCP and
file I/O; none can compile to `wasm32-wasip1` in a way that works inside `ngx_wasm_module`.
Therefore: **all LDAP/Kerberos authentication MUST run in the bridge sidecar**, with the
guest acting as an HTTP client via `dispatch_http_call`.

---

## 3. `meta.json` `config_schema`

```json
{
  "config_schema": {
    "type": "object",
    "properties": {
      "bridge_cluster": {
        "type": "string",
        "description": "IP or host:port of the ldap-bridge sidecar, reachable via dispatch_http_call"
      },
      "bridge_timeout_ms": { "type": "integer", "default": 1500 },
      "ldap_uri_template": {
        "type": "string",
        "description": "ldap(s):// URI template with %T (tenant) and %DC (DC host) placeholders; or fully in bridge config"
      },
      "base_dn_template": { "type": "string" },
      "user_filter_template": {
        "type": "string",
        "default": "(sAMAccountName=%s)"
      },
      "attributes_to_read": {
        "type": "array",
        "items": { "type": "string" },
        "default": ["sAMAccountName", "memberOf", "displayName", "mail"]
      },
      "tenant_resolvers": {
        "type": "array",
        "items": {
          "type": "object",
          "properties": {
            "tenant_id"        : { "type": "string" },
            "dc_host"          : { "type": "string" },
            "base_dn"          : { "type": "string" },
            "default_routing_tier": { "type": "string", "default": "standard" }
          },
          "required": ["tenant_id", "dc_host", "base_dn"]
        }
      },
      "routing_tier_map": {
        "type": "array",
        "items": {
          "type": "object",
          "properties": {
            "group_regex": { "type": "string" },
            "tier": { "type": "string" }
          },
          "required": ["group_regex", "tier"]
        }
      },
      "default_tier": { "type": "string", "default": "standard" },
      "require_tier": { "type": "boolean", "default": true },
      "allow_kerberos": { "type": "boolean", "default": true },
      "allow_basic":    { "type": "boolean", "default": true },
      "strip_authorization": { "type": "boolean", "default": true },
      "fail_open": { "type": "boolean", "default": false }
    },
    "required": ["bridge_cluster", "tenant_resolvers"]
  }
}
```

---

## 4. Bridge HTTP API Contract

### 4.1 `POST /ldap/bind`

Request:
```json
{
  "ldap_uri":     "ldaps://dc01.ad.corp:636",
  "base_dn":      "DC=corp,DC=example,DC=com",
  "user_filter":  "(sAMAccountName=%s)",
  "username":     "jdoe",
  "password":     "<redacted in logs>",
  "attributes":   ["sAMAccountName","memberOf","displayName","mail","customRoutingTier"]
}
```

Response (200, on bind + attribute read success):
```json
{
  "success": true,
  "user": {
    "dn":               "CN=jdoe,OU=Users,DC=corp,DC=example,DC=com",
    "sAMAccountName":   "jdoe",
    "displayName":       "Jane Doe",
    "mail":              "jdoe@corp.com"
  },
  "groups": [
    "CN=Finance-PowerUsers,OU=Groups,DC=corp,DC=example,DC=com",
    "CN=Domain Users,DC=corp,DC=example,DC=com"
  ],
  "attributes": { "customRoutingTier": "finance-power" },
  "tenant":    "corp"
}
```

Response (401 bind failed): `{"success": false, "error": "credentials_rejected"}`
Response (503 AD unreachable): `{"success": false, "error": "ad_unreachable", "retry_after": 5}`

### 4.2 `POST /krb/validate`

For Kerberos (when `allow_kerberos: true` and `Authorization: Negotiate <base64>`).

Request:
```json
{ "token": "<base64 KRB_AP_REQ from Authorization: Negotiate>", "service_spn": "HTTP/kong.corp.com@CORP.EXAMPLE.COM" }
```

Response (200): `{"success": true, "principal": "jdoe@CORP.EXAMPLE.COM", "realm": "CORP.EXAMPLE.COM", "pac_groups": [...], "source_host": "10.0.0.4"}`
Response (401): `{"success": false, "error": "krb_ap_req_invalid"}`
Response (503): KDC unreachable / replay cache unavailable.

The bridge holds the keytab at `/var/run/secrets/krb5/keytab` and the replay cache
(SQLite or in-memory keyed by authenticator+timestamp+cusec per RFC 4120). The guest
never sees the keytab.

### 4.3 `GET /healthz`

`{"status": "ok", "ldap_pool": "ok", "kerberos": "ok"}` (503 if any backend down).
Used by Kong's load balancer healthcheck.

### 4.4 Common response headers

- `X-Bridge-Latency-Ms`: integer, propagated by the guest into the audit log.
- `X-Bridge-Auth-Method`: `ldap` or `kerberos` : surfaced via `X-Auth-Method` on the
  downstream request.

---

## 5. Lifecycle Filter Implementation

```rust
struct LdapAuthFilter {
    config: Config,
    http_ctx_id: u32,
    pending_kind: PendingAuth,                // Basic { user, pass } | Negotiate { token }
    tenant_resolved: Option<TenantEntry>,
}

enum PendingAuth {
    None,
    Basic { user: String, password: String },
    Negotiate { token: String },
}

impl HttpContext for LdapAuthFilter {
    fn on_http_request_headers(&mut self, _: usize, _: bool) -> Action {
        // 1. Resolve tenant from context.
        let tenant_entry = match self.resolve_tenant() {
            Ok(t)  => t,
            Err(e) => return self.send_400(&e),
        };
        // 2. Extract auth.
        let auth_header = self.get_http_request_header("authorization")
            .unwrap_or_default();
        let kind = if auth_header.starts_with("Basic ") && self.config.allow_basic {
            let decoded = b64decode(&auth_header["Basic ".len()..]);
            let (u, p) = split_user_pass(&decoded)?;
            PendingAuth::Basic { user: u.to_string(), password: p.to_string() }
        } else if auth_header.starts_with("Negotiate ") && self.config.allow_kerberos {
            PendingAuth::Negotiate { token: auth_header["Negotiate ".len()..].to_string() }
        } else {
            return self.send_401_chall();
        };
        // 3. Validate username charset (LDAP-injection hardening).
        if let PendingAuth::Basic { user, .. } = &kind {
            if !is_user_safe(user) { return self.send_400("invalid_username"); }
        }
        // 4. Dispatch to the bridge.
        let (path, body) = match &kind {
            PendingAuth::Basic    { user, password } => (
                "/ldap/bind",
                serde_json_wasm::to_vec(&BindReq {
                    ldap_uri: tenant_entry.ldap_uri(),
                    base_dn:  tenant_entry.base_dn.clone(),
                    user_filter: self.config.user_filter_template.clone(),
                    username: user.clone(), password: password.clone(),
                    attributes: self.config.attributes_to_read.clone(),
                }).unwrap(),
            ),
            PendingAuth::Negotiate { token } => (
                "/krb/validate",
                serde_json_wasm::to_vec(&KrbReq {
                    token, service_spn: tenant_entry.krb_spn(),
                }).unwrap(),
            ),
        };
        self.pending_kind = kind;
        self.tenant_resolved = Some(tenant_entry.clone());
        match self.dispatch_http_call(
            &self.config.bridge_cluster,
            vec![(":method","POST"),
                 (":path", path),
                 (":authority", &self.config.bridge_cluster),
                 ("content-type","application/json")],
            Some(&body), vec![], Duration::from_millis(self.config.bridge_timeout_ms as u64),
        ) {
            Ok(_tok) => Action::Pause,
            Err(Status::BadArgument) => {
                self.send_http_response(500, vec![], Some(b"bridge misconfig\n"));
                Action::Pause
            }
            Err(_) => {
                self.send_http_response(503, vec![("Retry-After","2")], Some(b"bridge unreachable\n"));
                Action::Pause
            }
        }
    }
}

impl Context for LdapAuthFilter {
    fn on_http_call_response(&mut self, _t: u32, nh: usize, bs: usize, _nt: usize) {
        if nh == 0 && bs == 0 {
            // Timeout from the host. Never silent pass.
            self.send_http_response(503, vec![("Retry-After","5")], Some(b"ldap bridge timeout\n"));
            return;
        }
        let status = self.get_http_call_response_header(":status").unwrap_or_default();
        let body = self.get_http_call_response_body(0, bs).unwrap_or_default();
        if status != "200" {
            // Map 401 -> 401 challenge; 503 -> 503 retry-after; others -> 500.
            return self.send_failure_from_bridge(&status, &body);
        }
        if let Ok(auth_resp) = serde_json_wasm::from_slice::<AuthResp>(&body) {
            self.inject_context(&auth_resp);
            if self.config.strip_authorization {
                self.remove_http_request_header("authorization");
            }
            self.resume_http_request();
        } else {
            self.send_http_response(502, vec![], Some(b"malformed bridge response\n"));
        }
    }
}
```

**Pitfalls to handle** (from `PLUGIN-FOUNDATION.md` §6.3):
- `on_http_call_response` runs on the originating `HttpContext` in ngx_wasm_module when
  dispatched from `on_http_request_headers` (confirmed). Still call `set_effective_context`
  explicitly for forward compat.
- Reentrancy: do bookkeeping BEFORE `resume_http_request()`. Keep struct fields valid.
- Pseudo-header must be `:authority`, not `:host`.

---

## 6. Attribute Extraction + Context Injection

After a 200 from the bridge, the guest extracts from JSON:
- `user.sAMAccountName` → `x-user-id`
- `groups[]` (DN strings) → may filter through `routing_tier_map` regex to `x-routing-tier`
- `attributes.maxKeyLength-routing-tier` (if a custom AD attribute exposes the routing
  tier directly : short-circuit the group mapping) → `x-routing-tier`
- `tenant` (cluster/AD-forest mapping passed back by the bridge) → `x-tenant-id`
- `user.mail` → `x-user-mail` (optional, downstream consumer may use)

AD group → routing-tier mapping runs in the guest using `regex::Regex` (pure Rust,
compiles to wasip1). First-match wins (mirrors `ldap_authz_proxy` semantics):

```rust
fn resolve_tier(groups: &[String], map: &[TierRule], default: &str) -> String {
    for rule in map {
        if let Some(re) = COMPILED.find(&rule.group_regex) {
            for g in groups {
                if re.is_match(g) { return rule.tier.clone(); }
            }
        }
    }
    default.to_string()
}
```

Regex compilation cache at startup (`once_cell::Lazy` after `on_configure`).

---

## 7. Failure Modes

| Failure | Detection | Response |
|---------|-----------|----------|
| No Authorization header / not Basic / not Negotiate | header parse | 401 `WWW-Authenticate: Basic realm="<tenant>", Negotiate` (both challenges if both modes allowed) |
| Username unsafe chars (`[^A-Za-z0-9._-]`) | regex check | 400 `invalid_username` (LDAP-injection defense; user_filter templating done server-side anyway, but defense in depth) |
| Bridge unreachable (cosocket refused) | `dispatch_http_call` returns `Err` | 503 `Retry-After: 2` |
| Bridge timeout (`bridge_timeout_ms`) | `on_http_call_response` with `nh==0 && bs==0` | 503 `Retry-After: 5` |
| Bridge returns 401 (LDAP bind failed / Kerberos AP_REQ invalid) | HTTP 401 from bridge | 401 `WWW-Authenticate` realm challenge with `error="invalid_token", error_description="credentials rejected"` |
| Bridge returns 503 (AD/KDC unreachable) | HTTP 503 from bridge | 503 `Retry-After` forwarded from bridge's `Retry-After` header |
| Bridge 5xx other | HTTP 5xx | 502 `upstream_bridge_failed` |
| Bridge malformed JSON | `serde_json_wasm::from_slice` Err | 502 `malformed_bridge_response` |
| Tenant unresolved from request context | resolver Err | 400 `unknown_tenant` |
| Required routing tier missing (`require_tier: true`, no group matched) | tier resolver returns empty | 403 `missing_required_tier` |
| `fail_open: true` + bridge unreachable | all of above non-tenant failures | Action::Continue with `X-Auth-Error: bridge-unreachable` header + WARN log per AGENTS.md |

**No silent fallback (Rule 13):** `fail_open` default false. `true` is a deliberate
degraded-mode opt-in for low-stakes environments; the missing-tenant failure remains
fail-closed even when `fail_open: true` (a tenant resolution failure is a security
failure, not a bridge failure).

---

## 8. LDAP Bridge Service : Candidates and Build

There is **no canonical, production-grade OSS HTTP→LDAP REST gateway**. Candidates by
maintenance/activity:

| Project | Lang | Notes |
|---------|------|------|
| `JoWe112/ldapapi-ng` | Go (Gin) | LDAPS auth + user lookup REST, gateway-mode for KrakenD, k8s/Helm; clean endpoints. Lightest drop-in. |
| `bitai-cs/LDAPWebApi` | C# / .NET | OAuth2-secured REST proxy to AD; strongest production signal but heavyweight. |
| `elonen/ldap_authz_proxy` | Rust | nginx `auth_request`-style daemon; reads username from header, runs LDAP query, returns 200/403 and injects attributes into response headers. Adaptable. |
| GLAuth (popular) | Go | is an LDAP *server* (file/S3/LDAP backend), NOT an HTTP→LDAP validator; **not a fit**. |
| Custom Axum (`rskrb5` + `ldap3` Rust crates) | Rust | cleanest fit for this stack; see Section 9. |

**Recommended path:** write a small **Rust Axum bridge** using `ldap3` (pure-Rust LDAP
client) and `rskrb5` (pure-Rust Kerberos per `clelange/rskrb5`, which already has an
Axum `Negotiate` HTTP example). Single binary, no Python/.NET, ~500 LoC. Holds the
keytab and AD service-account creds via a mounted Secret; mTLS-terminates on the bridge
listener.

### 8.1 Axum bridge skeleton

```rust
// ldap-bridge/src/main.rs
use axum::{Router, routing::post, extract::Json, response::IntoResponse, http::StatusCode};
use ldap3::{LdapConn, Scope, SearchEntry};
use serde::{Deserialize, Serialize};

#[derive(Deserialize)] struct BindReq { ldap_uri: String, base_dn: String, user_filter: String, username: String, password: String, attributes: Vec<String> }
#[derive(Serialize)] struct BindResp { success: bool, user: UserResp, groups: Vec<String>, attributes: HashMap<String,String>, tenant: String }

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let app = Router::new()
        .route("/ldap/bind", post(ldap_bind))
        .route("/krb/validate", post(krb_validate))
        .route("/healthz", get(healthz));
    let listener = tokio::net::TcpListener::bind("0.0.0.0:8082").await?;
    axum::serve(listener, app).await?;
    Ok(())
}

async fn ldap_bind(Json(req): Json<BindReq>) -> impl IntoResponse {
    // tokio::task::spawn_blocking since ldap3 is synchronous.
    let res = tokio::task::spawn_blocking(move || -> anyhow::Result<BindResp> {
        let mut ldap = LdapConn::with_security(&req.ldap_uri, Security::Tls)?;   // LDAPS
        let dn = format!("CN={},OU=Users,{}", req.username, req.base_dn);   // or templated
        ldap.simple_bind(&dn, &req.password)?.success()?;
        // search for attributes & memberOf...
        let entries = ldap.search(&req.base_dn, Scope::Subtree, &req.user_filter.replace("%s", &req.username))?.success()?;
        // ... parse memberOf, custom attributes, return BindResp
    }).await;
    match res {
        Ok(Ok(r))  => (StatusCode::OK, Json(r)).into_response(),
        Ok(Err(_)) => (StatusCode::UNAUTHORIZED, Json(json!({"success":false,"error":"credentials_rejected"}))).into_response(),
        Err(_)     => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"success":false,"error":"bridge_internal"}))).into_response(),
    }
}
```

Build statically for `x86_64-unknown-linux-musl`. Wrap with mTLS termination
(`rustls` + `tokio-rustls`) when deployed off the localhost.

---

## 9. Security Constraints

- **mTLS on the bridge leg**: if non-localhost, the bridge must verify Kong's client
  cert. The credentials (password / Negotiate blob) flow only over mTLS : never plaintext.
- **Keytab/AD service-account credentials stay on the bridge**, never in the wasm module.
  The wasm guest is shared/reloadable and inspectable : secrets in the guest are a leak.
- **Credential logging suppression**: the guest MUST never pass the password /
  Negotiate blob to any `log::*` call. The bridge struct fields use
  `#[serde(skip_serializing)]` on the password and a custom `Debug` impl that redacts.
- **Strip `Authorization` on success** before forwarding upstream to prevent credential
  leakage to LLM providers; done via `remove_http_request_header("authorization")`.
- **LDAP injection hardening**: username charset validated in the guest
  (`^[A-Za-z0-9._-]+$`); the bridge uses parameterized searchesi (LDAP
  filter templating with proper escaping of metacharacters `* ( ) \ NUL`).
- **Replay cache (Kerberos)**: kept in the bridge; SQLite per RFC 4120 (`authenticator
  + cusec` keyed). The guest cannot run a replay cache (no in-VM shared state with
  time-sensitive semantics), reinforcing that validation belongs in the bridge.
- **No silent fallback** per AGENTS.md Rule 13: bridge timeout/down → 503, never
  `Action::Continue` with anonymous context (unless explicit `fail_open: true` for a
  dev tenant route : deliberate degraded-mode opt-in, logged as WARN every continue).

---

## 10. Test Plan (Required)

- Unit (guest): username charset regex; tenant resolution from Host/path/bootstrap
  headers; tier mapping regex first-match semantics; failure-to-503 conversion.
- Unit (bridge): `POST /ldap/bind` happy path against a mock LDAP server
  (`glauth` for CI); bind-only-failures → 401; search attribute extraction →
  correct `groups[]`/`attributes{}`. Mock AD unreachable → 503 with `Retry-After`.
- Unit (bridge): `POST /krb/validate` against a mock KDC (`mit-krb5-test-server` in
  Docker); valid AP_REQ → 200 with principal + pac_groups; invalid → 401.
- Integration: end-to-end through Kong + bridge + mock AD; assert `X-Tenant-ID`,
  `X-User-ID`, `X-Routing-Tier` injected; `Authorization` stripped; downstream
  receives headers.
- Integration: timeout injection (kill bridge → assert 503, never silent 200).
- Integration: LDAP injection attempt : username `"admin)(|(uid=*))"` → 400
  `invalid_username` (charset check) AND bridge applies escaping.
- Integration: replay cache : replay same Kerberos AP_REQ twice → second fails 401.
- Security: assert password never appears in any Kong log line; bridge log line; nor
  the Authorization blob.

---

## 11. Open Questions

| Q | Resolution |
|---|------------|
| Bridge implementation: in-house Axum (`ldap3`+`rskrb5`) vs adopt `ldapapi-ng` Go | In-house Rust recommended for monorepo consistency; `ldapapi-ng` acceptable if Go ops preferred |
| One bridge per tenant vs. one bridge with multi-DC pool | One bridge with pool (config-side DC per tenant); simpler deploy |
| MS-CHAPv2 / NTLM support | Out-of-scope v1 (legacy only); documented for v2 |
| Kerberos SPN per route | Configured in `tenant_resolvers[].krb_spn`; one SPN per tenant entry |
| Replay cache backend | in-memory by default with size cap; SQLite option for persistence across restarts |

---

## 12. References

- Proxy-Wasm spec, no-socket constraint: https://github.com/proxy-wasm/spec/blob/main/abi-versions/v0.2.1/README.md
- `dispatch_http_call` pause-dispatch-resume pattern: https://github.com/proxy-wasm/proxy-wasm-rust-sdk/blob/master/examples/http_auth_random/src/lib.rs
- Issue #172 (`:authority` vs `:host`, `BadArgument`): https://github.com/proxy-wasm/proxy-wasm-rust-sdk/issues/172
- Issue #230 (must use `dispatch_http_call`, not reqwest): https://github.com/proxy-wasm/proxy-wasm-rust-sdk/issues/230
- Promise PR #265 (ResumeHttpRequest contract): https://github.com/proxy-wasm/proxy-wasm-rust-sdk/pull/265
- `ldap3` Rust crate: https://github.com/ineo-forks/ldap3 (or `ineo/ldap3`)
- `rskrb5` pure-Rust Kerberos: https://github.com/clelange/rskrb5 (Axum negotiator example)
- MS-KKDCP spec: https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-kkdcp/
- RFC 4120 (Kerberos): https://datatracker.ietf.org/doc/html/rfc4120
- RFC 6750 (Bearer token usage, WWW-Authenticate): https://www.rfc-editor.org/rfc/rfc6750.html
- Kong `ldap-auth-advanced` (Enterprise, for schema reference): https://developer.konghq.com/plugins/ldap-auth-advanced/
- LDAP REST bridge candidates: `JoWe112/ldapapi-ng`, `bitai-cs/LDAPWebApi`, `elonen/ldap_authz_proxy`
- `glauth` (LDAP server, NOT a bridge : compare only): https://github.com/glauth/glauth
- Envoy `ext_authz` HTTP contract (canonical 200-inject/non-200-deny/error-503): https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/ext_authz_filter.html

---

**End of document.**