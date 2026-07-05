# WORKSPACE-GATEWAY

High-performance, enterprise, multi-tenant **LLM Gateway** built on
**Kong Gateway 3.14** (`kong/kong-gateway:3.14.0.4-debian`, Enterprise image run
unlicensed; all OSS features work in 3.14 free mode) in **traditional mode with
PostgreSQL**, plus four custom plugins that replace the Kong Enterprise-only
capabilities (`openid-connect`, `ldap-auth-advanced`, `ai-proxy-advanced`,
`ai-semantic-cache`) : and a PII redaction pipeline built from scratch.

> Part of the `Independent-Ai-Labs/WORKSPACE-VM` monorepo.
> Live spec docs in [`docs/`](docs/README.md). Implementation land is open.

---

## What this is

A single fault-tolerant edge that fronts OpenAI, Azure OpenAI, AWS Bedrock, Anthropic,
and self-hosted vLLM and provides:

- **Multi-IdP authentication** : OIDC/OAuth2 (Keycloak, Entra ID) **and** LDAP
  Windows Active Directory (LDAP bind + Kerberos SPN), zero user-directory sync.
- **Per-user, per-tenant virtual token billing** : audit-grade, billing-reconciled
  against upstream provider APIs; streaming-safe via enforced
  `stream_options.include_usage`.
- **Real-time PII anonymization & re-hydration** : regex / Aho-Corasick + optional
  NER inline; PII never reaches upstream LLM providers.
- **Semantic cache** : Redis VSS similarity lookup; cache hits skip upstream cost.
- **Adaptive multi-provider failover** : weighted load balancing (round-robin /
  consistent-hashing / least-connections / lowest-latency / lowest-usage / priority),
  circuit breakers, mid-flight retry on 429/5xx for non-streaming requests.

The data plane runs on **Kong Gateway 3.14** (Enterprise image, unlicensed). All OSS
features (Wasm, `ai-proxy`, custom plugins, Admin API) work in 3.14 free mode. Kong runs
in **traditional mode with PostgreSQL** (from the DATAOPS `ami-postgres` service),
providing writable Admin API, decK GitOps config management, and restart-survivability
even without an Enterprise license. The four Enterprise plugins are rebuilt as either
Rust Proxy-Wasm filters (inside `ngx_wasm_module`) or Lua plugins with Rust sidecars
for heavy lifting, all specified in `docs/`.

---

## Repository layout

```
WORKSPACE-GATEWAY/
├── README.md                 # this file
├── docs/                     # the architecture & plugin specifications
│   ├── README.md             # docs index + reading order
│   ├── PROPOSAL-LLM-GATEWAY-v2.md   # umbrella architecture (supersedes v1.0)
│   ├── PLUGIN-FOUNDATION.md         # shared build/host contract for all Wasm filters
│   ├── PLUGIN-REDACT-LUA.md          # thin in-process Lua Kong plugin shell
│   ├── PLUGIN-REDACT-ENGINE.md       # Rust redaction sidecar binary (the actual engine)
│   ├── PLUGIN-AUTH-OIDC.md           # Rust Proxy-Wasm filter: stateless JWT + JWKS
│   ├── PLUGIN-AUTH-LDAP.md           # Rust Proxy-Wasm filter + Axum LDAP/Kerberos bridge
│   ├── PLUGIN-SEMANTIC-CACHE.md      # Rust Proxy-Wasm filter + Redis VSS shim
│   └── PLUGIN-FAILOVER.md            # Lua plugin + Rust translator sidecar (Bedrock/SigV4)
└── res/
    └── LOGO_RAW.png
```

Source subdirectories for each plugin will be created under the project root once
implementation begins (e.g. `plugins/auth-oidc-filter/`, `plugins/redact-engine/`,
`plugins/failover-translator/`, etc.). All plugin specs reference this structure.

---

## Architecture (high-level)

```
[ Inbound App Clients ]
        |  (JWT / Bearer / Kerberos ticket)
        v
+----------------------------------------------------------------+
| KONG AI DATA PLANE  (Kong Gateway 3.14, traditional mode + PostgreSQL)  |
|                                                                |
| Phase 1: Unified Auth Engine                                  |
|   PLUGIN-AUTH-OIDC   cached-JWKS stateless JWT validation      |
|   PLUGIN-AUTH-LDAP   LDAP bind / Kerberos SPN via HTTP bridge |
|   -> injects X-Tenant-ID / X-User-ID / X-Routing-Tier         |
|                                                                |
| Phase 2: PII Anonymization                                    |
|   PLUGIN-REDACT-LUA   in-process thin shell (cosocket dispatch)|
|   PLUGIN-REDACT-ENGINE  Rust sidecar (aho-corasick + NER)      |
|   request: redact -> stash PII map in kong.ctx.plugin          |
|   response: body_filter re-hydration (local gsub)              |
|                                                                |
| Phase 3: AI Proxy + Custom Routing                            |
|   PLUGIN-SEMANTIC-CACHE  Redis VSS cosine cache (>= 0.95 sim)  |
|   PLUGIN-FAILOVER  weighted LB + 429/5xx failover + translation|
|   ai-proxy (bundled)  canonical OpenAI format translation     |
|                                                                |
| Log phase (off-thread, ngx.timer.at / kong.async):           |
|   ai.proxy.usage.* -> Vector -> ClickHouse + Prometheus       |
+----------------------------------------------------------------+
        |  (Stripped PII + Per-target API key)
        v
[ Upstream Providers ]  (OpenAI / Azure / Bedrock / Anthropic / vLLM)

[ Sidecars ]
  redact-engine  : aho-corasick + optional tract ONNX NER
  ldap-bridge    : Axum wrapping ldap3 + rskrb5, mTLS, keytab in bridge
  cache-shim     : Redis VSS HTTP front (redisvl SemanticCache wrapper)
  failover-translator : Bedrock SigV4 + bidirectional SSE translation
```

---

## OSS vs Enterprise correction

The original draft of this proposal was titled "Kong OSS" but advertised three
Enterprise-only capabilities. After technical due diligence, the following four
Enterprise plugins are rebuilt as custom components on top of Kong Gateway 3.14
(Enterprise image run unlicensed; all OSS features work in 3.14 free mode):

| Kong Enterprise plugin missing from OSS | Replaced by |
|------------------------------------------|------------|
| `openid-connect` | `PLUGIN-AUTH-OIDC` (Rust Proxy-Wasm, JWKS cache + `dispatch_http_call` refresh, RFC 6750 responses) |
| `ldap-auth-advanced` | `PLUGIN-AUTH-LDAP` (Rust Proxy-Wasm + Axum bridge holding the keytab; guest cannot open sockets) |
| `ai-proxy-advanced` | `PLUGIN-FAILOVER` (Lua access-phase + `ngx.shared.dict` + Rust translator sidecar for Bedrock : pure Proxy-Wasm would break SSE streaming because `dispatch_http_call` buffers the whole response) |
| `ai-semantic-cache` | `PLUGIN-SEMANTIC-CACHE` (Rust Proxy-Wasm + Redis VSS HTTP shim : guest cannot speak RESP3 directly) |

The redaction plugin has no Kong Enterprise analogue : `ai-sanitizer` (Enterprise) also
delegates to an external PII service, which we replicate with our own Rust engine.

See [`docs/PROPOSAL-LLM-GATEWAY-v2.md`](docs/PROPOSAL-LLM-GATEWAY-v2.md) §0 for the
full documented correction table.

---

## Build targets (per spec)

| Component | Language | Build command | Target |
|-----------|----------|----------------|--------|
| Auth OIDC filter | Rust Proxy-Wasm | `cargo build --release` | `wasm32-wasip1` |
| Auth LDAP filter | Rust Proxy-Wasm | `cargo build --release` | `wasm32-wasip1` |
| Semantic Cache filter | Rust Proxy-Wasm | `cargo build --release` | `wasm32-wasip1` |
| Failover Lua plugin | Lua | drop-in Kong plugin dir | : |
| Redact Lua plugin | Lua | drop-in Kong plugin dir | : |
| Redact-engine sidecar | Rust native | `cargo build --release` | `x86_64-unknown-linux-gnu` |
| LDAP bridge sidecar | Rust native (Axum) | `cargo build --release` | `x86_64-unknown-linux-gnu` |
| Cache shim | Rust native (axum) or Go | TBD | `x86_64-unknown-linux-gnu` |
| Failover translator | Rust native (axum + reqsign) | `cargo build --release` | `x86_64-unknown-linux-gnu` |

**Proxy-Wasm constraints** all Wasm filters respect (see
[`docs/PLUGIN-FOUNDATION.md`](docs/PLUGIN-FOUNDATION.md)):
- `proxy-wasm = "0.2.5"` (NOT 0.3.0-dev : unreleased, ABI v0.3 unsupported by
  `ngx_wasm_module`).
- Target `wasm32-wasip1` (Rust 1.84+; `wasm32-wasi` is the older name).
- Core-wasm module, **NOT** a Wasm component : `ngx_wasm_module` does not run a
  component runtime.
- Crate-type `cdylib`; `panic = "abort"` (panics trap the instance); explicit error
  propagation, no `unwrap()` on hostcalls.
- meta.json `config_schema` MUST be JSON Schema **Draft-4** (other drafts rejected).
- Guest cannot open TCP sockets (`dispatch_http_call` is the only outbound primitive;
  gRPC dispatch is NYI in ngx_wasm_module). All TCP-only protocols (Redis, LDAP,
  Kerberos) require HTTP-bridge sidecars.

---

## Sidecar inventory

| Sidecar | Listens on | Holds secrets | Spec |
|---------|-----------|-----------------|------|
| `redact-engine` | `127.0.0.1:8081` | OpenAI embedding key, optional ONNX model weights | `PLUGIN-REDACT-ENGINE.md` |
| `ldap-bridge` | `127.0.0.1:8082` | AD service-account creds, Kerberos keytab | `PLUGIN-AUTH-LDAP.md` §8 |
| `cache-shim` | `127.0.0.1:8090` | OpenAI embedding key, Redis connection | `PLUGIN-SEMANTIC-CACHE.md` §4 |
| `failover-translator` | `127.0.0.1:8091` | AWS credentials (SigV4) | `PLUGIN-FAILOVER.md` §9 |

All sidecars MUST mTLS-terminate when deployed off-pod; the Wasm guest never sees any
secrets. No silent fallback on bridge timeout : see each plugin's failure-mode table
and `docs/PLUGIN-FOUNDATION.md` §9.

---

## Billing-grade contract

Per `docs/PROPOSAL-LLM-GATEWAY-v2.md` §5.2, the gateway enforces:

1. `stream_options.include_usage: true` on every streaming route to every provider
   that supports it (injected by `PLUGIN-FAILOVER` access-phase).
2. Kong version pin **3.14** (`kong/kong-gateway:3.14.0.4-debian`; OTLP Gen-AI metrics
   + Prometheus `consumer` labels). Traditional mode with PostgreSQL ensures
   restart-survivability even without an Enterprise license.
3. Per-type token breakdown stored separately (`prompt_tokens`, `completion_tokens`,
   `reasoning_tokens`, `cached_tokens`) : never summed into `total_tokens` for billing
   math (per Kong bug #14816).
4. **Rate snapshots** stored at request time for reproducible historical bills.
5. **Daily reconciler job** cross-checks ClickHouse ledger against OpenAI/Azure usage
   APIs; divergence flagged to `billing_discrepancies` table, never silently dropped.

ClickHouse schema uses `Decimal64(6)` for `cost` (NOT `Float64` : MPP aggregates
non-deterministic with floats), `PARTITION BY toYYYYMM(timestamp)`, TTL 13 months,
`ORDER BY (tenant_id, user_id, timestamp)` for prefix-pruned per-tenant aggregate
queries.

---

## Status

**Phase: specification complete, implementation not started.**

All nine specs in `docs/` are research-validated drafts with citations, failure-mode
tables, test plans, and open questions. Implementation begins once the specs land a
stakeholder review signoff; per-plugin specs each define their own test plan that must
pass before merge (no `#[allow]` / no silent fallback per the workspace
`AGENTS.md` rules).

---

## Reading order

1. [`docs/PROPOSAL-LLM-GATEWAY-v2.md`](docs/PROPOSAL-LLM-GATEWAY-v2.md) : revised
   umbrella architecture & rationale.
2. [`docs/PLUGIN-FOUNDATION.md`](docs/PLUGIN-FOUNDATION.md) : shared build/host/state
   contracts inherited by every Wasm filter.
3. Per-plugin specs in `docs/` : consult the relevant one during implementation.
4. [`docs/README.md`](docs/README.md) : full docs index, license posture, and reading
   order.

---

## License posture

- **Kong Gateway 3.14** (`kong/kong-gateway:3.14.0.4-debian`, Enterprise image run
  unlicensed): all OSS features (Wasm, `ai-proxy`, custom plugins, Admin API) work in
  3.14 free mode. Traditional mode with PostgreSQL ensures restart-survivability.
  No Enterprise license required for normal operation.
- **Custom plugins** are bespoke, written for this project (license TBD with the
  workspace maintainer : see `AGENTS.md`).
- **Sidecar dependencies**: `aho-corasick`, `regex`, `rsa`/`p256`/`ed25519-dalek`
  (RustCrypto), `tract` (Sonos ONNX runtime), `ldap3`, `rskrb5`, `redisvl` (Redis
  SemanticCache), `axum`, `reqsign` : all MIT or Apache-2.0.
- **No code has been committed yet** : these are specifications only.

---

## References

- Kong WebAssembly / Proxy-Wasm in Kong (beta in 3.4, GA in 3.11, bundled in 3.14):
  https://konghq.com/blog/product-releases/gateway-3-4-oss
- `Kong/ngx_wasm_module` (Kong-authored Proxy-Wasm host):
  https://github.com/Kong/ngx_wasm_module
- Proxy-Wasm Rust SDK: https://crates.io/crates/proxy-wasm
- Kong AI Gateway audit log reference:
  https://developer.konghq.com/ai-gateway/ai-audit-log-reference/
- Open bugs informing the billing-grade contract:
  [`Kong/kong#14535`](https://github.com/Kong/kong/issues/14535) (streaming
  completion_tokens=0),
  [`Kong/kong#14816`](https://github.com/Kong/kong/issues/14816) (reasoning tokens
  not summed).
- Industry redaction precedents:
  [`wan9yu/kong-plugin-argus-redact`](https://github.com/wan9yu/kong-plugin-argus-redact),
  [`wan9yu/argus-redact`](https://github.com/wan9yu/argus-redact),
  [`developer.konghq.com/plugins/ai-sanitizer`](https://developer.konghq.com/plugins/ai-sanitizer/)
- Redis VSS reference: [`redis/redis-vl-py`
  `SemanticCache`](https://redis.io/docs/latest/develop/ai/redisvl/user_guide/how_to_guides/llmcache/)

---

**Maintained by:** AMI-Agents Engineering  
**Last updated:** 2026-07-04  
**Document set version:** v2.0 (revised : supersedes v1.0 "Kong OSS" proposal)