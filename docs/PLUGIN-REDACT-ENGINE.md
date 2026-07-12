# Plugin Spec: NER Engine - Rust Sidecar Binary (v2)

**Document ID:** AMI-PROP-LLMGW-PLUGIN-REDACT-ENGINE-v2.0
**Status:** Draft (v2, optional enhancement, not required for v1)
**Date:** 2026-07-05
**Parent:** `PROPOSAL-LLM-GATEWAY-v3.md`; inherits `PLUGIN-FOUNDATION.md`
**Companion:** `PLUGIN-REDACT-LUA.md` (the Lua plugin that calls this service)

This document specifies the **optional NER (Named Entity Recognition) sidecar**:
a standalone Rust HTTP service deployed alongside APISIX. It owns structural PII
detection (Person/Org/Location) that regex cannot reliably catch. The Lua redaction
plugin calls this service **off-thread** via `ngx.timer.at`, the request path is
never blocked.

**v2, not implemented in v1.** v1 uses regex + dictionary detection only (pure
Lua, zero sidecars). This sidecar is an opt-in enhancement for environments that
need named-entity detection beyond structured PII patterns.

---

## 1. Architecture

```
                     Rust NER engine sidecar (single binary)
                    +--------------------------------------------------+
HTTP/JSON in --->  | axum/hyper server  (POST /ner, /healthz)         |  ---> HTTP/JSON out
(from Lua plugin   |                                                  |
 ngx.timer.at)     | ONNX Runtime BERT-tiny int8 inference             |
                    |   - Person (PER), Organization (ORG),             |
                    |     Location (LOC) entities                       |
                    |   - BIO tag decoding -> entity spans              |
                    |   - runs on tokio::task::spawn_blocking threads   |
                    |                                                  |
                    | No regex, no dictionary, no redaction token minting  |
                    | (all of that is in the Lua plugin now)           |
                    +--------------------------------------------------+
```

**Why a separate binary (not in Lua):**
- BERT-tiny inference takes 10-100ms per clause (CPU-bound). The nginx worker is
  single-threaded; inline inference would block all connections on that worker.
- The sidecar has its own thread pool (`tokio::task::spawn_blocking`); inference
  runs without touching the proxy.
- ONNX Runtime (C++ via `ort` crate) gives hardware-accelerated inference; not
  available inside LuaJIT.
- Single static binary, no Python VM, no model server dependency.

**Why it's optional (v2):**
- Structured PII (email, SSN, credit card, API key, phone, JWT) is caught by
  regex in the Lua plugin. This covers the majority of PII leakage risk.
- NER adds person names, organization names, and locations, valuable but not
  blocking for v1.
- The sidecar is called off-thread; if it's down or slow, the Lua plugin falls
  back to regex-only redaction for that segment. No request is blocked.

---

## 2. API

### 2.1 `POST /ner`

Request:
```json
{
  "text": "Hi, I'm John Smith from Acme Corp. Call me at 555-1234.",
  "correlation_id": "req-abc-123"
}
```

Response (200):
```json
{
  "entities": [
    { "kind": "person_name", "text": "John Smith", "start": 7, "end": 17 },
    { "kind": "organization", "text": "Acme Corp", "start": 23, "end": 32 }
  ],
  "model": "bert-tiny-ner-int8",
  "latency_ms": 12
}
```

The Lua plugin receives entities and applies them to the PII map (minting
redaction tokens like `[CUSTOMER_NAME_1]`, `[ORGANIZATION_1]`). Redaction token minting
and PII map management stay in the Lua plugin, the sidecar only detects.

### 2.2 `GET /healthz`

```json
{
  "status": "ok",
  "model": "bert-tiny-ner-int8",
  "uptime_secs": 12345,
  "inference_count": 9847
}
```

### 2.3 Response headers

All responses carry:
- `X-Engine-Latency-Ms`: integer latency of the NER inference.
- `X-Model-Name`: model identifier.
- `Content-Type: application/json`.

---

## 3. Cargo.toml

```toml
[package]
name = "ner-engine"
version = "2.0.0"
edition = "2021"

[[bin]]
name = "ner-engine"
path = "src/main.rs"

[dependencies]
axum = "0.7"
tokio = { version = "1", features = ["full"] }
tower = "0.5"
hyper = { version = "1", features = ["full"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
ort = { version = "2", features = ["download-binaries"] }  # ONNX Runtime
tokenizers = "0.20"                                         # HuggingFace tokenizers
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
thiserror = "1"
anyhow = "1"
uuid = { version = "1", features = ["v4"] }
once_cell = "1"

[profile.release]
lto = true
opt-level = 3
codegen-units = 1
strip = "debuginfo"
```

**Build:** `cargo build --release --target x86_64-unknown-linux-gnu`.
NATIVE binary (not wasm). SIMD available. ONNX Runtime linked via `ort` crate.

---

## 4. NER Pipeline

### 4.1 Model loading (at startup)

```rust
use ort::{Environment, Session, SessionBuilder, Value};
use tokenizers::Tokenizer;

pub struct NerModel {
    session: Session,
    tokenizer: Tokenizer,
    label_map: Vec<String>,  // ["O","B-PER","I-PER","B-ORG","I-ORG","B-LOC","I-LOC"]
}

impl NerModel {
    pub fn load(model_path: &str, tokenizer_path: &str) -> Result<Self> {
        let env = Environment::builder()
            .with_name("ner-engine")
            .build()?;
        let session = SessionBuilder::new(&env)?
            .with_optimization_level(ort::session::GraphOptimizationLevel::Level3)?
            .with_intra_threads(4)?
            .with_model_from_file(model_path)?;
        let tokenizer = Tokenizer::from_file(tokenizer_path)?;
        let label_map = default_bio_labels();
        Ok(Self { session, tokenizer, label_map })
    }
}
```

### 4.2 Inference (on blocking thread)

```rust
impl NerModel {
    pub fn detect(&self, text: &str) -> Result<Vec<Entity>> {
        let encoding = self.tokenizer.encode(text, true)?;
        let input_ids = encoding.get_ids();
        let attention_mask = encoding.get_attention_mask();

        // Convert to ONNX input tensors
        let input_ids_tensor = Value::from_array(input_ids)?;
        let attention_tensor = Value::from_array(attention_mask)?;

        // Run inference
        let outputs = self.session.run(vec![input_ids_tensor, attention_tensor])?;
        let logits = outputs[0].try_extract_tensor::<f32>()?;

        // BIO decode -> Vec<Entity>
        bio_decode(logits, &self.label_map, text, input_ids)
    }
}

#[derive(Serialize)]
pub struct Entity {
    pub kind: String,       // "person_name", "organization", "location"
    pub text: String,       // the matched text
    pub start: usize,       // byte offset in original text
    pub end: usize,
}
```

### 4.3 BIO decoding

Standard BIO (Begin-Inside-Outside) tag decoding:
- `B-PER` starts a person entity; `I-PER` continues it.
- `B-ORG` starts an organization entity; `I-ORG` continues it.
- `B-LOC` starts a location entity; `I-LOC` continues it.
- `O` is outside any entity.

Entity kind mapping: `PER` -> `person_name`, `ORG` -> `organization`,
`LOC` -> `location`.

### 4.4 Model choice

| Model | Size | Dim | Latency | License |
|-------|------|-----|---------|---------|
| `bert-tiny-ner-int8` (recommended) | ~15MB | 128 | 10-30ms | Apache 2.0 |
| `xtremedistil-l12-h384` quantized | ~30MB | 384 | 20-60ms | MIT |
| `bert-base-ner` (full) | ~110MB | 768 | 50-150ms | Apache 2.0 |

Bundle the model into the container image. For multi-tenant per-tenant dictionaries
(not NER models, those are global), use the Lua plugin's file-based dictionary.

---

## 5. Threading Model

- `axum` runs an async multi-threaded Tokio runtime. Default = number of CPU cores.
- HTTP handlers are async; they yield at `await` points.
- **All ONNX inference runs on `tokio::task::spawn_blocking` threads** (default
  pool size = 4). This keeps the async runtime responsive while NER computes on
  dedicated worker threads.
- Model loaded once at startup; lives in `Arc<NerModel>` shared across handlers.
  No per-request model loading.

```rust
async fn ner_handler(
    State(model): State<Arc<NerModel>>,
    Json(req): Json<NerRequest>,
) -> impl IntoResponse {
    let model = model.clone();
    let result = tokio::task::spawn_blocking(move || {
        model.detect(&req.text)
    }).await;

    match result {
        Ok(Ok(entities)) => (StatusCode::OK, Json(NerResponse { entities, ... })).into_response(),
        Ok(Err(e)) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error":"ner_failed"}))).into_response(),
        Err(_) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error":"pool_panicked"}))).into_response(),
    }
}
```

---

## 6. Deployment

### 6.1 Sidecar (same host as APISIX)

```yaml
# docker-compose.yml (excerpt)
services:
  ner-engine:
    image: registry.internal/ner-engine:2.0.0
    ports:
      - "127.0.0.1:8081:8081"
    environment:
      - NER_MODEL_PATH=/models/bert-tiny-ner-int8.onnx
      - NER_TOKENIZER_PATH=/models/bert-tiny-tokenizer.json
      - RUST_LOG=info
    volumes:
      - ./models:/models:ro
    deploy:
      resources:
        limits:
          memory: 512M
          cpus: "2"
```

### 6.2 Standalone (non-localhost)

When deployed off-host, run with `--tls-cert` / `--tls-key` / `--tls-ca-cert`.
mTLS ensures only APISIX can call the engine.

### 6.3 Systemd user binary (alternative to Docker)

Follow the llamaserver pattern: deploy as a systemd user unit via Ansible.
Binary at `$WORKSPACE_ROOT/services/ner-engine/ner-engine`, model
files at `$WORKSPACE_ROOT/services/ner-engine/models/`.

---

## 7. Lua Plugin Integration

The Lua redaction plugin calls this sidecar via `ngx.timer.at` (off-thread):

```lua
-- In redact.lua access phase, after regex redaction:
if conf.ner_sidecar_url and conf.ner_sidecar_url ~= "" then
    local req_id = core.request.header(ctx, "x-request-id") or ""
    local text_to_ner = extract_text_for_ner(parsed.messages)
    ngx.timer.at(0, function(premature)
        if premature then return end
        local http = require("resty.http")
        local httpc = http.new()
        httpc:set_timeout(conf.ner_timeout_ms)
        local res, err = httpc:request_uri(conf.ner_sidecar_url .. "/ner", {
            method = "POST",
            body = cjson.encode({ text = text_to_ner, correlation_id = req_id }),
            headers = { ["Content-Type"] = "application/json" },
        })
        if res and res.status == 200 then
            local ner = cjson.decode(res.body)
            -- Merge NER entities into ctx.redact_key (if body_filter hasn't run yet)
            -- Best-effort: if body_filter already ran, NER results are lost (acceptable)
            if ner and ner.entities then
                for _, ent in ipairs(ner.entities) do
                    local kind = string.upper(ent.kind)
                    ctx.ner_counter = (ctx.ner_counter or 0) + 1
                    local redaction token = string.format("[%s_%d]", kind, ctx.ner_counter)
                    ctx.redact_key[redaction token] = ent.text
                end
            end
        end
        httpc:set_keepalive()
    end)
end
```

**Timing constraint:** NER runs off-thread. If `body_filter` fires before the
NER sidecar returns, NER entities are not in the PII map and re-hydration uses
regex-only redaction for that segment. This is acceptable, NER is best-effort
enrichment layered on top of the fast regex guarantee.

---

## 8. Failure Modes

| Failure | HTTP | Behavior |
|---------|------|----------|
| Malformed request (no `text` field) | 400 | `{"error":"missing_text"}` |
| Text too long (> 10kB) | 413 | `{"error":"payload_too_large"}` |
| ONNX inference fails | 500 | `{"error":"ner_inference_failed","detail":"..."}` |
| Tokenizer fails | 500 | `{"error":"tokenization_failed"}` |
| Model not loaded (startup failure) | (process exits non-zero at boot) | Never serve half-initialized |
| Panic in handler | 500 | `{"error":"panic"}` (axum catch_unwind) |

**Never silent:** every non-2xx carries an `error` field. The Lua plugin treats
any failure as "NER unavailable for this request", regex redaction still
applies. No request is blocked or failed due to NER sidecar issues.

---

## 9. Observability

- `tracing` structured logs (JSON if `RUST_LOG=json`); input text NEVER logged.
- Prometheus metrics endpoint (`GET /metrics`):
  - `ner_engine_requests_total`
  - `ner_engine_inference_seconds_bucket` (histogram)
  - `ner_engine_entities_total{kind}` (person_name/organization/location)
  - `ner_engine_failures_total{error_type}`

---

## 10. Security Constraints

- **No PII in logs:** custom `tracing` filter redacts input text from all log
  lines (replaced with `<REDACTED_INPUT>`). Entity text is also redacted in logs;
  only entity kind and count are logged.
- **No PII in metrics labels:** never include original text in Prometheus labels;
  only `kind` (person_name/organization/location).
- **mTLS for non-localhost:** required when not co-located with APISIX.
- **Memory:** NER model ~15-110MB RSS; container limit >= 512Mi.
- **No silent fallback:** on internal error, emit non-2xx; Lua plugin surfaces
  via regex-only fallback (acceptable degradation, not silent failure).

---

## 11. Test Plan

- Unit: `NerModel::detect` with fixture model, assert "John Smith" detected as
  PER, "Acme Corp" as ORG.
- Unit: BIO decoding, B-PER followed by I-PER produces one entity (not two).
- Unit: empty text -> empty entities (not error).
- Integration: `POST /ner` with mixed text -> correct entity spans.
- Integration: kill model file at startup -> process exits non-zero.
- Integration: runtime inference failure (corrupt input) -> 500 with error body.
- Performance: <30ms per clause with BERT-tiny int8 (benchmark in CI).
- Security: assert no input text appears in any log line or metric label.

---

## 12. Open Questions

| Q | Resolution |
|---|------------|
| Model source for BERT-tiny NER int8 | Vendor from `microsoft/xtremedistil-l12-h384-uncased` quantized, or fine-tune BERT-tiny on CoNLL-2003 |
| `tokenizers` crate compilation | HF Rust binding to C++ core; ships pre-built for `x86_64-linux`. If undesirable, hand-roll WordPiece tokenizer (~500 LoC) |
| Multi-language NER | v2: English-only (BERT-tiny). v3: add multilingual model (XLM-RoBERTa) if non-English tenants need it |
| NER result timing vs body_filter race | Acceptable: NER is best-effort. If timer hasn't returned, regex-only redaction applies. Document this in integration guide. |

---

## 13. References

- `ort` crate (Rust ONNX Runtime bindings): https://crates.io/crates/ort
- `tokenizers` (HuggingFace): https://github.com/huggingface/tokenizers
- `axum` web framework: https://github.com/tokio-rs/axum
- BERT-tiny distillation: https://huggingface.co/google/bert_uncased_L-2_H-128_A-2
- CoNLL-2003 NER dataset: https://www.clips.uantwerpen.be/conll2003/ner/
- BIO tag decoding: https://en.wikipedia.org/wiki/Inside%E2%80%93outside%E2%80%93beginning_(tagging)
- `lua-resty-http` (caller side): https://github.com/ledgetech/lua-resty-http
- APISIX `ngx.timer.at`: https://github.com/openresty/lua-nginx-module#ngxtimerat

---

**End of document.**
