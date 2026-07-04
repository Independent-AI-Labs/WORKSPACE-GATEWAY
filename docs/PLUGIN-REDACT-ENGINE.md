# Plugin Spec: PII Redaction - Rust Engine Sidecar

**Document ID:** AMI-PROP-LLMGW-PLUGIN-REDACT-ENGINE-v1.0
**Status:** Draft
**Date:** 2026-07-04
**Parent:** `PROPOSAL-LLM-GATEWAY-v2.md`; inherits `PLUGIN-FOUNDATION.md`
**Companion:** `PLUGIN-REDACT-LUA.md` (the in-process Lua shell that calls this service)

This document specifies the **actual redaction engine** : a standalone Rust HTTP service
deployed as a sidecar alongside Kong. It owns the real work: Aho-Corasick + regex
detection, dictionary matching, optional inline NER via `tract` (ONNX runtime in pure
Rust), placeholder minting, and the reverse-key apply. The Lua Kong plugin is a thin
shell that calls this service; this Rust binary does all the computation.

**Why a standalone Rust binary and not inside the Lua/wasm guest:**
- The nginx worker is single-threaded; Aho-Corasick + NER cannot block it. A sidecar
  process has its own thread pool : heavy regex / NER runs without touching the proxy.
- Pure Rust gives us `aho-corasick` (no_std-capable, pure Rust) and `regex` crates with
  SIMD-accelerated scalar matchers : much faster than the Lua implementations.
- `tract` (pure-Rust ONNX runtime) lets us embed a tiny NER model (BERT-tiny int8) inline
  if desired : inside the sidecar's worker thread, not the nginx worker, so the proxy
  never blocks even on a 50ms NER pass.
- Single static binary, no Python VM, no PyO3 bridge : operational simplicity.

---

## 1. Architecture

```
                    Rust redaction engine sidecar (single binary)
                   +--------------------------------------------------+
HTTP/JSON in --->  | axum/hyper server  (POST /redact, /restore,     |  ---> HTTP/JSON out
(from Lua plugin)  |                       /healthz)                  |
                   |                                                  |
                   | Layer 1: aho-corasick + regex matrix (always on) |
                   |   - email, SSN, credit card, API key, phone      |
                   |   - dictionary (per-profile)                     |
                   |                                                  |
                   | Layer 2: NER (optional, config-driven)           |
                   |   - tract ONNX BERT-tiny int4 inline, OR         |
                   |   - delegate to a separate ONNX sidecar via HTTP |
                   |                                                  |
                   | Placeholder minter                                |
                   |   - per-profile strategies                       |
                   |   - atomic, token-monotonic (never split in SSE) |
                   |                                                  |
                   | Reverse-key apply (POST /restore, rarely used)   |
                   +--------------------------------------------------+
```

Deployed as:
- A sidecar container in the Kong pod (same localhost network), OR
- A standalone service in the private cluster network (with mTLS to Kong).

---

## 2. Cargo.toml

```toml
[package]
name = "redact-engine"
version = "1.0.0"
edition = "2021"

[[bin]]
name = "redact-engine"
path = "src/main.rs"

[dependencies]
# HTTP server
axum = "0.7"
tokio = { version = "1", features = ["full"] }
tower = "0.5"
hyper = { version = "1", features = ["full"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"

# Redaction core
aho-corasick = "0.7"               # pure Rust; no_std-capable; SIMD disabled but scalar is ~2-5x slower than native
regex = "1"                         # pure Rust; SIMD disabled in wasi targets : here we run NATIVE so SIMD is ON

# NER (optional)
tract-onnx = { version = "0.21", optional = true }   # pure-Rust ONNX runtime
tokenizers = { version = "0.20", optional = true }   # HuggingFace tokenizers, optional

# Logging / config
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
config = "0.14"

# Errors
thiserror = "1"
anyhow = "1"

# Misc
uuid = { version = "1", features = ["v4"] }
once_cell = "1"
rustls = "0.23"                     # mTLS server (if non-localhost deployment)
tokio-rustls = "0.26"

[features]
default = ["ner-tract"]
ner-tract = ["dep:tract-onnx", "dep:tokenizers"]
ner-sidecar = []   # NER delegated to a separate HTTP service
ner-off = []
```

**Build:** `cargo build --release --target x86_64-unknown-linux-gnu`. This is a NATIVE
binary, NOT wasm32-wasip1 (we're running on the sidecar, not inside the proxy). SIMD is
available. Use `--no-default-features --features ner-off` to disable NER entirely.

---

## 3. HTTP API

### 3.1 `POST /redact`

Request:
```json
{
  "messages": [
    {"role": "user", "content": "Hi, I'm John Smith, SSN 123-45-6789. Email me at john@example.com."}
  ],
  "profile": "pseudonym-llm",         // selects regex/dictionary/NER config
  "stream":  false                    // signals SSE placeholder atomicity expectations
}
```

Response (200):
```json
{
  "redacted_messages": [
    {"role": "user", "content": "Hi, I'm [CUSTOMER_NAME_1], SSN [SSN_1]. Email me at [EMAIL_1]."}
  ],
  "key": {
    "[CUSTOMER_NAME_1]": "John Smith",
    "[SSN_1]": "123-45-6789",
    "[EMAIL_1]": "john@example.com"
  },
  "placeholder_count": 3,
  "transaction_id": "9f3c2a01-...",
  "ner_used": true,
  "engine_latency_ms": 8
}
```

Response non-2xx → see Section 9 (failure modes).

### 3.2 `POST /restore`

For non-`body_filter` contexts (e.g. webhook callbacks, async pipelines). The Lua
`body_filter` does local substitution instead (no cosocket allowed there), but this
endpoint exists for completeness and for the future async-redaction use case.

Request:
```json
{
  "text": "Hi, I'm [CUSTOMER_NAME_1], SSN [SSN_1].",
  "key": { "[CUSTOMER_NAME_1]": "John Smith", "[SSN_1]": "123-45-6789" }
}
```

Response (200):
```json
{"restored": "Hi, I'm John Smith, SSN 123-45-6789."}
```

### 3.3 `GET /healthz`

Response (200): `{"status":"ok","version":"1.0.0","ner_mode":"tract|sidecar|off","uptime_secs":12345}`

Used by Kong's load balancer healthcheck + the Lua plugin's optional liveness probe.

### 3.4 Response headers (mandatory)

All responses carry:
- `X-Engine-Latency-Ms`: integer latency of the redaction work (propagated by the Lua
  plugin into the audit log via `ctx.redact_engine_latency_ms`).
- `X-Engine-Ner-Used`: `"true"`/`"false"` : surfaced in audit log.
- `X-Transaction-Id`: matched on the redact request/response.
- `Content-Type: application/json`.

---

## 4. Redaction Pipeline (Layered)

### 4.1 Layer 1 : Aho-Corasick + regex (always on, <1ms)

Built once at startup from the configured `profile`:

```rust
use aho_corasick::AhoCorasick;
use regex::Regex;

pub struct Layer1Detector {
    ac: AhoCorasick,                    // multi-pattern dictionary
    patterns: Vec<Regex>,               // regex matrix for structured PII
    pattern_kinds: Vec<DetectedKind>,    // email, ssn, card, api_key, phone, custom
}

pub enum DetectedKind {
    Email, Ssn, CreditCard, ApiKey, PhoneNumber, Custom(String),
}
```

Default profile `pseudonym-llm` ships these patterns (config-overridable):

| Kind | Regex |
|------|-------|
| Email | `(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b` |
| SSN (US) | `\b\d{3}-\d{2}-\d{4}\b` |
| Credit card | `\b(?:\d[ -]*?){13,16}\b` (with Luhn check to suppress false positives) |
| API key | `\b(?i)(sk|pk|key)-[A-Za-z0-9]{20,}\b` (OpenAI/Anthropic styles) |
| Phone | `\b\+?\d{1,3}?[-.\s]?\(?\d{3}\)?[-.\s]?\d{3,4}[-.\s]?\d{4}\b` |
| JWT | `\beyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b` |
| IPv4 | `\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b` (only if `redact_ips: true`) |

Aho-Corasick covers the **dictionary** (named persons / orgs / project codes per
tenant profile) : fast multi-pattern exact match. The `aho_corasick` crate is pure Rust
with SIMD acceleration on the native target (`x86_64-unknown-linux-gnu`); the engine
scales linearly with text length.

Luhn check on credit card candidates prevents the regex hitting 16-digit invoice IDs.
Build the detector once at startup (`once_cell::sync::Lazy`), share across requests.

### 4.2 Layer 2 : NER (optional)

`profile.ner_mode`:
- `off` : skip; only Layer 1.
- `tract` : inline ONNX inference via `tract-onnx` (default feature).
- `sidecar` : delegate to a separate ONNX service (HTTP).

#### Inline tract (default when NER enabled)

```rust
use tract_onnx::tract::prelude::*;

pub struct TractNerModel {
    model: RunnableModel,
    tokenizer: tokenizers::Tokenizer,
    label_map: Vec<String>,         // ["O","B-PER","I-PER","B-ORG","I-ORG","B-LOC","I-LOC",...]
}

impl TractNerModel {
    pub fn load(model_path: &str, tokenizer_path: &str) -> Result<Self> {
        let model = tract_onnx::onnx()
            .model_for_path(model_path)?
            .into_optimized()?
            .into_runnable()?;
        let tokenizer = tokenizers::Tokenizer::from_file(tokenizer_path)?;
        Ok(Self { model, tokenizer, label_map: default_bio_labels() })
    }

    pub fn detect(&self, text: &str) -> Vec<Entity> {
        // Tokenize -> run inference on a tokio::task::spawn_blocking thread
        // (NEVER on the axum async handler thread : NER is 10-100ms CPU-bound)
        let encoding = self.tokenizer.encode(text, true)?;
        let input_ids = encoding.get_ids().to_vec();
        let attention_mask = encoding.get_attention_mask().to_vec();
        // ... tensor conversion, model.run (...) ...
        // BIO decoding -> Vec<Entity { kind, span, text }>
    }
}
```

**Critical:** All `tract` inference runs on a `tokio::task::spawn_blocking` thread,
giving the axum async handler a chance to keep serving other requests while NER
computes. The axum runtime is multi-threaded (unlike the nginx worker). Configurable
blocking-thread pool size (default 4). NER in the sidecar therefore does NOT block
the proxy even though NER in the wasm guest WOULD.

#### Sidecar mode

Delegating to `POST /ner` on an external ONNX service (uses `reqwest`). Used when:
- You want to share an ONNX model across multiple redact-engines in the cluster.
- The model is too heavy for sidecar memory budget.
- The NER model is updated frequently without redeploying the engine.

Same `Entity` schema returned; the engine conflates dictionary + sidecar results.

### 4.3 Entity merge + placeholder minting

Both layers emit `Entity { kind, span: Range<usize>, text: String }`. Merge by span;
on overlap, prefer Layer 2 (NER named entities) over Layer 1 (regex patterns), unless
Layer 1 has a stronger confidence (custom dict : confidence 1.0).

Placeholder strategy by `profile`:

| `profile` | Strategy |
|-----------|---------|
| `pseudonym-llm` (default) | `[KIND_N]` e.g. `[EMAIL_1]`, `[SSN_1]`, `[CUSTOMER_NAME_1]`. N increments per kind per call, stable within one `/redact` call. |
| `synthetic` | Replace with category-typed alternatives (`John` -> `Amir`, `City A` -> `Metropolis`) : for clients that need naturalistic-looking redactions. Specified separately. |
| `fixed-token` | Fixed per-kind-value tokens (same original -> same placeholder within the call AND across calls if `session_stable: true`). |

**Atomicity guarantee:** placeholders are fixed ASCII tokens (`[A-Z_0-9]+`). They never
include regex metacharacters in the inner body (only `[`, `]`, `_`, digits, uppercase :
all safe for the Lua gsub with-escape path). The engine NEVER emits a placeholder that
spans a token in the produced text : the LLM cannot split `[EMAIL_1]` because the
placeholder is a single atomic string replaced after the LLM generates text.

---

## 5. Per-Profile Configuration

`profiles/<name>.toml`:

```toml
[redact]
kind_patterns = [
    { kind = "email", regex = "(?i)\\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}\\b" },
    { kind = "ssn",  regex = "\\b\\d{3}-\\d{2}-\\d{4}\\b" },
    # ... credit card, api key, phone, jwt, ipv4
]
luhn_check_kinds = ["credit_card"]
dictionary_kinds = ["person_name", "org_name"]   # matched via AhoCorasick PLUS NER

[ner]
mode = "tract"                                   # "off" | "tract" | "sidecar"
model_path = "models/bert-tiny-int8.onnx"
tokenizer_path = "models/bert-tiny-tokenizer.json"
labels = ["O", "B-PER", "I-PER", "B-ORG", "I-ORG", "B-LOC", "I-LOC"]
entity_kind_map = { "PER" = "customer_name", "ORG" = "organization", "LOC" = "location" }
ner_sidecar_url = ""                             # only when mode=sidecar

[placeholder]
style = "pseudonym-llm"                          # pseudonym-llm | synthetic | fixed-token
session_stable = false
```

---

## 6. Reverse-key Apply (Restore)

```rust
pub fn restore_with_key(text: &str, key: &HashMap<String, String>) -> String {
    let mut result = text.to_string();
    for (placeholder, original) in key {
        // Plain (non-pattern) substitution; placeholders are guaranteed safe ASCII.
        result = result.replace(placeholder, original);
    }
    result
}
```

`String::replace` in Rust is plain substring match (no regex semantics), so
metacharacters in placeholders are handled correctly. This mirror-image is exposed via
`POST /restore` but the Lua side does it locally to honour the cosocket ban in
`body_filter`.

---

## 7. Threading Model

- `axum` runs an async multi-threaded Tokio runtime. Default = number of CPU cores.
- HTTP handlers are async; they yield at `await` points on sidecar calls / DB.
- **CPU-bound work (aho-corasick, regex, tract)** runs on
  `tokio::task::spawn_blocking` threads (default pool size = 4). This keeps the async
  runtime responsive while heavy NER passes occur on dedicated worker threads.
- Disk I/O (loading ONNX model, dictionary) happens once at startup; loaded models
  live in `Arc<Lazy<TractNerModel>>` shared across handlers, no per-request reload.

---

## 8. Deployment

### 8.1 Sidecar (same pod)

```yaml
# k8s pod template (illustrative)
spec:
  containers:
    - name: kong
      image: kong:3.14
      env:
        - name: KONG_WASM
          value: "on"
        - name: KONG_WASM_FILTERS_PATH
          value: "/opt/kong/wasm"
    - name: redact-engine
      image: registry.internal/redact-engine:1.0.0
      ports:
        - containerPort: 8081
      resources:
        limits:
          memory: "512Mi"
          cpu: "2000m"
        requests:
          memory: "256Mi"
          cpu: "500m"
      env:
        - name: REDACT_ENGINE_LISTEN
          value: "0.0.0.0:8081"
        - name: REDACT_ENGINE_PROFILE
          value: "pseudonym-llm"
        - name: REDACT_NER_MODE
          value: "tract"            # or "off" or "sidecar"
```

### 8.2 Standalone (non-localhost)

When deployed off-pod, the engine must run with `--tls-cert` / `--tls-key` /
`--tls-ca-cert` flags (rustls). The Lua plugin's `engine_url` is `https://...`. mTLS
ensures only Kong can call the engine; the PII never crosses a public network in
plaintext.

### 8.3 SHM zone sizing : NOT APPLICABLE

Unlike `PLUGIN-FAILOVER` (which uses `kong.ctx`/SHM), the engine is stateless across
requests beyond loaded models. No nginx SHM zone sizing concern.

---

## 9. Failure Modes

| Failure | HTTP | Body |
|---------|------|------|
| Unknown profile | 400 | `{"error":"unknown_profile","profile":"..."}` |
| Malformed messages (not OpenAI shape) | 400 | `{"error":"malformed_messages"}` |
| Message content not a string | 400 | `{"error":"content_not_string","message_index":N}` |
| Tract model load fails at startup | (process exits non-zero at boot) | log + abort : never serve half-initialized |
| Tract inference fails at runtime | 500 | `{"error":"ner_inference_failed","detail":"..."}` : Lua treats per `on_error` (503 closed / unredacted+header open). NER failure should NOT block Layer 1 redaction: emit redacted messages from Layer 1 alone, set `ner_used:false` + `X-Engine-Ner-Failed: 1`. |
| Aho-Corasick / regex panic | (panics trap the handler; axum returns 500) | log + 500 : Lua 503-closed / open-unredacted |
| Request body too large | 413 | `{"error":"payload_too_large","max":1048576}` |
| Internal JSON serialization error | 500 | `{"error":"serialization_failed"}` |

**Never silent:** every non-2xx response carries an `error` field; the Lua plugin
surfaces it. No silent 200. No silent PII leakage.

**Layer 1 always-on guarantee:** if NER is enabled and fails on a request, the engine
MUST still return Layer 1 redacted output with `ner_used:false` and a side-channel
header : never return a 500 that forces the Lua plugin to choose closed/unredacted
when Layer 1 already succeeded. This is critical for graceful degradation: regex PII
(email, SSN, card) is always caught even if NER is broken.

---

## 10. Performance SLO

- Layer 1 (aho-corasick + regex): <1ms per kB of input text (native SIMD, scalar
  fallback for non-SIMD hosts is ~2-5x slower but still linear).
- Layer 2 NER (tract BERT-tiny int8, block-on-blocking pool): 10-100ms per clause.
- HTTP roundtrip overhead (axum/hyper, localhost): 0.1-0.5ms.
- Total `/redact` latency budget per message: <20ms fast path, <150ms with NER.

**Hot-path optimization:** pre-compile regex & build AhoCorasick once at startup
(`Lazy::new`). Models loaded once. Profiles hot-loadable via SIGHUP for ops without
restart, but not required.

---

## 11. Observability

- `tracing` structured logs (JSON if `RUST_LOG=json`); redaction contents NEVER logged :
  only metadata (`profile`, `placeholder_count`, `ner_used`, `latency_ms`).
- Prometheus metrics endpoint (`GET /metrics`):
  - `redact_engine_requests_total{profile,ner_mode}`
  - `redact_engine_redact_seconds_bucket` (histogram)
  - `redact_engine_placeholders_total{kind}`
  - `redact_engine_ner_seconds_bucket`
  - `redact_engine_failures_total{error_type}`
- The Lua plugin surfaces `redact.placeholder_count`, `redact.engine_latency_ms`,
  `redact.ner_used` in the Kong audit log; the engine exposes process-level metrics for
  operations dashboards.

---

## 12. Security Constraints

- **No PII in logs:** the engine's `tracing` layer explicitly redacts the input text from
  log lines (replaced with `<REDACTED_INPUT>`). The placeholder map is also redacted. A
  custom `tracing::Subscriber` filter enforces this.
- **No PII in metrics labels:** never include original text/PII in Prometheus labels :
  only `kind` (email/ssn/customer_name/...), never the value.
- **mTLS for non-localhost:** required when the engine is not in the same pod as Kong.
- **Memory hints:** NER models may consume up to 200MB RSS when loaded; the OOM-killer
  guard requires ≥512Mi container limit; load only one model per engine process by default.
- **Panic handling:** every handler wrapped in `tokio::task::catch_unwind` (or axum's
  default panic hook) so a single bad input doesn't kill the engine. The HTTP response is
  500 with `{"error":"panic","detail":"..."}`.
- **No silent fallback:** per AGENTS.md Rule 13, on any internal error the engine emits
  a non-2xx or a 200-with-`ner_used=false`+`X-Engine-Ner-Failed` : never silently 200
  redaction-failed-as-if-it-succeeded.

---

## 13. Test Plan (Required)

- Unit: `Layer1Detector::detect` with every kind pattern; assert span offsets.
- Unit: `restore_with_key` round-trip (redact then restore = original text).
- Unit: Luhn check rejects 16-digit invoice IDs, accepts valid test card numbers.
- Unit: `TractNerModel` (if enabled) : load fixture model, detect "John Smith" as PER.
- Integration: `POST /redact` with mixed PII email + name; assert redacted + key shape.
- Integration: kill NER (rename model file, fail to load at startup) → engine exits
  non-zero (no half-init serving).
- Integration: NER runtime failure injection (return Err from detect) → Layer 1 still
  returns redacted output with `ner_used:false`.
- Performance: <1ms/kB Layer 1 + <150ms with NER (benchmark in CI).
- Security: assert no input text appears in any log line, any metric label.

---

## 14. Open Questions

| Q | Resolution |
|---|------------|
| Model source for BERT-tiny int8 NER | Bundle into the container image or load from `models/` ConfigMap; vendor from a known repo (e.g. `microsoft/xtremedistil-l12-h384-uncased` quantized) |
| Tokenizers crate compilation | `tokenizers` is HF's Rust binding to a C++ core; ships pre-built for `x86_64-linux`. If this adds undesirable weight, write a hand-rolled WordPiece BPE tokenizer (~500 LoC, no C dep). Decide before v1 freeze. |
| Streaming placeholder atomicity across LLM token boundaries | Confirmed: placeholders are full ASCII tokens; LLMs only split them in pathological tokenization. For full safety the engine returns the redacted prompt with placeholders on text-level, not token-level; the tokenization happens upstream (the LLM itself). Document this in the integration guide. |
| Multi-tenancy | Engine receives `messages` only; tenant-scoped dictionaries could be loaded per `profile` keyed by tenant ID, but v1 has one profile per route (tenant-aware routing is the Kong layer's concern). v2 may add `X-Tenant-ID` passthrough for per-tenant dictionaries. |

---

## 15. References

- `aho-corasick` crate (pure Rust, SIMD): https://github.com/BurntSushi/aho-corasick
- `regex` crate: https://github.com/rust-lang/regex
- `tract` ONNX runtime (pure Rust): https://github.com/sonos/tract
- `tokenizers` (HF, optional): https://github.com/huggingface/tokenizers
- `axum` web framework: https://github.com/tokio-rs/axum
- argus-redact Python sidecar precedent: https://github.com/wan9yu/argus-redact
- Kong `ai-sanitizer` external-service contract: https://developer.konghq.com/plugins/ai-sanitizer/
- Luhn algorithm: https://en.wikipedia.org/wiki/Luhn_algorithm
- BERT-tiny distillation candidates: https://huggingface.co/microsoft/xtremedistil-l12-h384-uncased

---

**End of document.**