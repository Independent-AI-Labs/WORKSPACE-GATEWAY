# SPEC-REDACT-ENGINE: Optional Rust NER Sidecar Implementation

**Date:** 2026-07-17
**Status:** Draft
**Type:** Specification
**Requirements:** [REQ-REDACT-ENGINE](../requirements/REQ-REDACT-ENGINE.md)

> Intended design of the optional NER sidecar: a single static Rust binary
> (axum + ONNX Runtime, BERT-tiny int8) that detects Person/Organization/
> Location entities for the Lua `redact` plugin. Inference runs on blocking
> threads; the Lua caller invokes it off-thread via `ngx.timer.at`. This is a
> v2 opt-in enhancement to the implemented regex+dictionary Lua redaction
> (SPEC-REDACT); nothing here exists in the codebase yet.

---

**Cross-references:**
- [REQ-REDACT-ENGINE](../requirements/REQ-REDACT-ENGINE.md): requirements contract
- SPEC-REDACT / REQ-REDACT: implemented Lua regex+dictionary redaction predecessor ([`plugins/custom/redact.lua`](../../plugins/custom/redact.lua), [`plugins/custom/redact_lib.lua`](../../plugins/custom/redact_lib.lua))
- Legacy PLUGIN-REDACT-ENGINE design (v2, optional, absorbed)
- [`SPEC-REDACT.md`](SPEC-REDACT.md): Lua plugin spec (caller side)

---

## 1. Overview

The sidecar owns structural PII detection that regex cannot catch. It is a
separate process because BERT inference is CPU-bound (10-100ms per clause)
and the nginx worker is single-threaded; ONNX Runtime is unavailable inside
LuaJIT. The Lua plugin keeps regex, dictionaries, redaction token minting,
and PII map management; the sidecar only detects.

## 2. Architectural Principles

### 2.1 Detection only

No regex, no dictionary, no token minting in the sidecar.

### 2.2 Never block the proxy

Inference runs on `tokio::task::spawn_blocking` threads; the Lua caller runs
off-thread via `ngx.timer.at`. Sidecar failure degrades to regex-only
redaction for that segment.

### 2.3 Never silent, never leaky

Every non-2xx carries an `error` field. Input text and entity text never
appear in logs or metric labels.

### 2.4 Fail fast at boot

Model load failure exits the process non-zero; a half-initialized engine is
never served.

## 3. System Diagram

```
                     Rust NER engine sidecar (single binary)
                    +--------------------------------------------------+
HTTP/JSON in --->  | axum/hyper server  (POST /ner, /healthz, /metrics)| ---> HTTP/JSON out
(from Lua plugin   |                                                  |
 ngx.timer.at)     | ONNX Runtime BERT-tiny int8 inference             |
                    |   - PER / ORG / LOC entities                     |
                    |   - BIO tag decoding -> entity spans             |
                    |   - tokio::task::spawn_blocking threads          |
                    |                                                  |
                    | No regex, no dictionary, no token minting        |
                    +--------------------------------------------------+
```

## 4. HTTP API

### 4.1 `POST /ner`

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

The Lua plugin mints redaction tokens (e.g. `[CUSTOMER_NAME_1]`,
`[ORGANIZATION_1]`) from these spans; the sidecar does not.

### 4.2 `GET /healthz`

```json
{
  "status": "ok",
  "model": "bert-tiny-ner-int8",
  "uptime_secs": 12345,
  "inference_count": 9847
}
```

### 4.3 Response headers

| Header | Value |
|--------|-------|
| `X-Engine-Latency-Ms` | integer NER inference latency |
| `X-Model-Name` | model identifier |
| `Content-Type` | `application/json` |

### 4.4 Error responses

| Failure | HTTP | Body |
|---------|------|------|
| Missing `text` field | 400 | `{"error":"missing_text"}` |
| Text > 10kB | 413 | `{"error":"payload_too_large"}` |
| ONNX inference failure | 500 | `{"error":"ner_inference_failed","detail":"..."}` |
| Tokenizer failure | 500 | `{"error":"tokenization_failed"}` |
| Model not loaded | process exits non-zero at boot | never serves |
| Handler panic | 500 | `{"error":"panic"}` (axum catch_unwind) |

## 5. Build Configuration

Key dependencies (Cargo.toml sketch):

| Crate | Version | Role |
|-------|---------|------|
| `axum` | 0.7 | HTTP server |
| `tokio` | 1 (full) | async runtime |
| `ort` | 2 (`download-binaries`) | ONNX Runtime bindings |
| `tokenizers` | 0.20 | HuggingFace tokenizers |
| `serde`/`serde_json` | 1 | JSON |
| `tracing` + `tracing-subscriber` | 0.1 / 0.3 | structured logs |

Release profile: `lto = true`, `opt-level = 3`, `codegen-units = 1`,
`strip = "debuginfo"`. Native `x86_64-unknown-linux-gnu` binary (not wasm).

## 6. NER Pipeline

### 6.1 Startup

`NerModel::load(model_path, tokenizer_path)` builds the ONNX session
(`GraphOptimizationLevel::Level3`, `with_intra_threads(4)`), loads the
tokenizer JSON, and the BIO label map
`["O","B-PER","I-PER","B-ORG","I-ORG","B-LOC","I-LOC"]`. The model is wrapped
in `Arc<NerModel>` shared across handlers.

### 6.2 Inference

Tokenize -> build `input_ids` / `attention_mask` tensors -> `session.run` ->
extract `f32` logits -> `bio_decode` to `Vec<Entity>`:

| Entity field | Meaning |
|--------------|---------|
| `kind` | `person_name` / `organization` / `location` |
| `text` | matched substring |
| `start` / `end` | byte offsets in the original text |

### 6.3 BIO decoding

`B-PER` starts a person entity; `I-PER` continues it. Same for `ORG`/`LOC`.
`O` is outside any entity. Mapping: PER -> `person_name`, ORG ->
`organization`, LOC -> `location`.

### 6.4 Model choice

| Model | Size | Dim | Latency | License |
|-------|------|-----|---------|---------|
| `bert-tiny-ner-int8` (recommended) | ~15MB | 128 | 10-30ms | Apache 2.0 |
| `xtremedistil-l12-h384` quantized | ~30MB | 384 | 20-60ms | MIT |
| `bert-base-ner` (full) | ~110MB | 768 | 50-150ms | Apache 2.0 |

Model files are bundled into the container image.

## 7. Threading Model

- axum on a multi-threaded Tokio runtime (default: CPU core count).
- Handlers are async; all ONNX inference runs inside
  `tokio::task::spawn_blocking` (default pool 4).
- No per-request model loading; `Arc<NerModel>` cloned into the blocking task.

## 8. Deployment

### 8.1 Docker sidecar (same host as APISIX)

```yaml
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

### 8.2 Standalone (non-localhost)

Run with `--tls-cert` / `--tls-key` / `--tls-ca-cert`; mTLS ensures only
APISIX can call the engine.

### 8.3 Systemd user binary

Llamaserver pattern: binary at `$WORKSPACE_ROOT/services/ner-engine/`,
models under `services/ner-engine/models/`, deployed as a systemd user unit
via Ansible.

## 9. Lua Plugin Integration (intended)

In the `redact` plugin access phase, after regex redaction, when
`ner_sidecar_url` is configured: extract NER text from request messages and
POST `{text, correlation_id}` to `{ner_sidecar_url}/ner` inside
`ngx.timer.at`. On 200, merge entities into `ctx.redact_key` as
`[{KIND_UPPER}_{n}] -> entity text` entries using a per-request counter.

**Timing constraint:** if `body_filter` fires before the timer returns, NER
entities are lost for that segment; regex-only redaction applies. Accepted as
best-effort enrichment layered over the fast regex guarantee.

## 10. Observability and Security

- `tracing` structured logs (JSON with `RUST_LOG=json`); input text replaced
  with `<REDACTED_INPUT>`; entity text redacted, only kind + count logged.
- Prometheus `GET /metrics`: `ner_engine_requests_total`,
  `ner_engine_inference_seconds_bucket`,
  `ner_engine_entities_total{kind}`, `ner_engine_failures_total{error_type}`.
- No original text in metric labels. mTLS required off-localhost. Container
  memory limit >= 512Mi.

## 11. Edge Cases & Decisions

- **NER vs body_filter race:** accepted; documented as best-effort.
- **Multi-language:** v2 English-only; multilingual model (XLM-RoBERTa) is a v3 consideration.
- **Per-tenant dictionaries:** remain in the Lua plugin's file-based dictionary; NER models are global.

## 12. File Map

| File | Purpose | Key Changes |
|------|---------|-------------|
| `services/ner-engine/` crate (planned) | axum server, ONNX pipeline | new Rust binary |
| `plugins/custom/redact.lua` (planned edit) | optional `ner_sidecar_url` timer call | add off-thread NER merge |
| deployment configs (planned) | compose service or systemd unit | add ner-engine service |

## 13. Implementation Status

| Component | Status | Evidence |
|-----------|--------|----------|
| `ner-engine` Rust crate/binary | Not implemented | no `Cargo.toml` or Rust sources in repo; no `services/ner-engine/` |
| ONNX model + tokenizer assets | Not implemented | no `*.onnx` or tokenizer JSON in repo |
| Lua integration (`ner_sidecar_url`) | Not implemented | grep `ner` in `plugins/custom/redact.lua` and `redact_lib.lua`: no match |
| Deployment unit (compose/systemd) | Not implemented | no `ner-engine` service in deployment configs or `res/` |
| Metrics/logging filters | Not implemented | no sidecar code exists |
| Tests | Not implemented | no `tests/**` referencing NER |
