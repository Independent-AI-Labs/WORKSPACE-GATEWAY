# REQ-REDACT-ENGINE: Optional Rust NER Sidecar

**Date:** 2026-07-17
**Status:** Draft
**Type:** Requirements
**Specification:** [SPEC-REDACT-ENGINE](../specifications/SPEC-REDACT-ENGINE.md)

> This document mandates the intended design of an optional Named Entity
> Recognition (NER) sidecar: a single Rust binary (axum + ONNX Runtime,
> BERT-tiny int8) exposing `POST /ner` for Person/Organization/Location
> detection. It is a v2 opt-in enhancement layered on top of the implemented
> Lua `redact` plugin (regex + dictionary, see REQ-REDACT / SPEC-REDACT). The
> sidecar is called off-thread via `ngx.timer.at`; if it is down or slow, the
> gateway falls back to regex-only redaction and no request is ever blocked.
> Nothing in this document is implemented in the current codebase.

---

**Cross-references:**
- [SPEC-REDACT-ENGINE](../specifications/SPEC-REDACT-ENGINE.md): companion specification
- REQ-REDACT / SPEC-REDACT: implemented Lua regex+dictionary redaction predecessor ([`plugins/custom/redact.lua`](../../plugins/custom/redact.lua), [`plugins/custom/redact_lib.lua`](../../plugins/custom/redact_lib.lua))
- Legacy PLUGIN-REDACT-ENGINE design (AMI-PROP-LLMGW-PLUGIN-REDACT-ENGINE-v2.0, absorbed)
- [`SPEC-REDACT`](../specifications/SPEC-REDACT.md): Lua plugin spec that calls this service

---

## 1. Purpose & Scope

### 1.1 Purpose

Define requirements for structural PII detection (person names, organization
names, locations) that regex cannot reliably catch, delivered as an optional
sidecar so that CPU-bound neural inference never blocks an nginx worker.

### 1.2 Scope

**This document OWNS the requirements for:**
- The NER sidecar HTTP API (`POST /ner`, `GET /healthz`)
- The ONNX/BERT inference pipeline and BIO decoding behavior
- Threading model (async runtime + blocking inference pool)
- Failure, security, and observability requirements for the sidecar
- The integration contract with the Lua `redact` plugin

**This document DOES NOT:**
- Own regex/dictionary PII detection or redaction token minting (owned by the Lua `redact` plugin)
- Require deployment of the sidecar (it is opt-in; absence MUST degrade gracefully)
- Cover multi-language NER (v2 is English-only)

### 1.3 Terminology

| Term | Definition |
|------|------------|
| NER | Named Entity Recognition |
| BIO | Begin-Inside-Outside tag scheme for entity spans |
| ONNX Runtime | C++ inference engine bound via the Rust `ort` crate |
| Entity kind | `person_name`, `organization`, `location` |
| Off-thread call | `ngx.timer.at` timer; never on the request hot path |

## 2. Functional Requirements

### FR-1: NER API

| ID | Requirement |
|----|-------------|
| FR-1.1 | The sidecar MUST expose `POST /ner` accepting `{"text": string, "correlation_id": string}`. |
| FR-1.2 | The sidecar MUST return 200 with `{"entities": [{kind, text, start, end}], "model": string, "latency_ms": int}` where `start`/`end` are byte offsets in the original text. |
| FR-1.3 | Entity kinds MUST be limited to `person_name` (PER), `organization` (ORG), `location` (LOC). |
| FR-1.4 | BIO decoding MUST merge `B-X` followed by `I-X` into a single entity span. |
| FR-1.5 | Empty input text MUST return an empty entity list (not an error). |
| FR-1.6 | The sidecar MUST expose `GET /healthz` returning status, model name, uptime, and inference count. |
| FR-1.7 | All responses MUST carry headers `X-Engine-Latency-Ms`, `X-Model-Name`, and `Content-Type: application/json`. |

### FR-2: Inference Pipeline

| ID | Requirement |
|----|-------------|
| FR-2.1 | The model MUST be loaded once at startup and shared across requests via `Arc`; per-request model loading is forbidden. |
| FR-2.2 | All ONNX inference MUST run on `tokio::task::spawn_blocking` threads so the async runtime stays responsive. |
| FR-2.3 | The default model SHOULD be `bert-tiny-ner-int8` (~15MB, 10-30ms per clause, Apache 2.0). |
| FR-2.4 | If the model fails to load at startup, the process MUST exit non-zero and MUST NOT serve half-initialized. |
| FR-2.5 | Tokenization MUST use a HuggingFace `tokenizers` JSON file loaded at startup. |

### FR-3: Lua Plugin Integration

| ID | Requirement |
|----|-------------|
| FR-3.1 | The Lua `redact` plugin MUST call the sidecar only when `ner_sidecar_url` is configured, and only via `ngx.timer.at` (off-thread). |
| FR-3.2 | NER results MUST be merged into the PII map as additional redaction tokens (e.g. `[PERSON_NAME_1]`, `[ORGANIZATION_1]`); token minting remains owned by the Lua plugin. |
| FR-3.3 | If `body_filter` runs before the NER timer returns, NER results for that segment MAY be dropped; regex-only redaction applies. This race is acceptable and MUST be documented. |
| FR-3.4 | Any sidecar failure (non-2xx, timeout, unreachable) MUST be treated as "NER unavailable for this request"; the request MUST NOT be blocked or failed. |

## 3. Non-Functional Requirements

| ID | Requirement |
|----|-------------|
| NFR-1.1 | Input text MUST NEVER appear in any log line; a tracing filter replaces it with `<REDACTED_INPUT>`. Entity text MUST also be redacted in logs; only kind and count may be logged. |
| NFR-1.2 | Prometheus metric labels MUST NOT contain original text; only `kind`. |
| NFR-1.3 | Metrics endpoint `GET /metrics` SHOULD expose `ner_engine_requests_total`, `ner_engine_inference_seconds` histogram, `ner_engine_entities_total{kind}`, `ner_engine_failures_total{error_type}`. |
| NFR-1.4 | Non-localhost deployments MUST use mTLS (`--tls-cert`/`--tls-key`/`--tls-ca-cert`) so only APISIX can call the engine. |
| NFR-1.5 | Every non-2xx response MUST carry an `error` field; failures are never silent. |
| NFR-1.6 | BERT-tiny int8 inference SHOULD complete in <30ms per clause. |
| NFR-1.7 | Container memory limit SHOULD be >= 512Mi (model RSS ~15-110MB). |

## 4. Constraints

| ID | Constraint | Source |
|----|------------|--------|
| C-1 | No regex, no dictionary, no token minting in the sidecar; detection only | legacy redact-engine spec §1 |
| C-2 | Single static native binary (not wasm); ONNX Runtime via `ort` crate | legacy redact-engine spec §3 |
| C-3 | Off-thread invocation only; nginx worker must never block on inference | legacy redact-engine spec §1 |
| C-4 | English-only in v2 | legacy redact-engine spec §12 |

## 5. Assumptions

| ID | Assumption |
|----|------------|
| A-1 | A suitable quantized NER model can be vendored (e.g. fine-tuned BERT-tiny on CoNLL-2003). |
| A-2 | The sidecar is deployed co-located with APISIX on localhost for the common case. |
| A-3 | Structured PII (email, SSN, card, API key, phone, JWT) is already covered by the Lua regex path. |

## 6. Open Questions

| Q | Resolution |
|---|------------|
| Model source for BERT-tiny NER int8 | Vendor quantized `xtremedistil-l12-h384-uncased` or fine-tune BERT-tiny on CoNLL-2003 |
| `tokenizers` crate native dependency | Ships pre-built for x86_64-linux; hand-rolled WordPiece (~500 LoC) is the fallback |
| NER-vs-`body_filter` race | Accepted; best-effort enrichment, regex-only fallback |

## 7. Verification Matrix

| # | Test | Maps to |
|---|------|---------|
| V1 | Unit: fixture model detects "John Smith" as PER, "Acme Corp" as ORG | FR-1.2, FR-1.3 |
| V2 | Unit: B-PER + I-PER yields one entity span | FR-1.4 |
| V3 | Unit: empty text yields empty entities | FR-1.5 |
| V4 | Integration: `POST /ner` returns correct byte-offset spans | FR-1.2 |
| V5 | Integration: missing model file at boot exits non-zero | FR-2.4 |
| V6 | Integration: corrupt input yields 500 with error body | NFR-1.5 |
| V7 | Performance: <30ms per clause (CI benchmark) | NFR-1.6 |
| V8 | Security: no input text in any log line or metric label | NFR-1.1, NFR-1.2 |

## 8. Implementation Status

| Item | Status | Evidence |
|------|--------|----------|
| FR-1.x NER HTTP API | Not implemented | no Rust crate or `ner-engine` binary in codebase |
| FR-2.x inference pipeline | Not implemented | no `Cargo.toml`, no ONNX/tokenizer assets in repo |
| FR-3.1 `ner_sidecar_url` in Lua plugin | Not implemented | `plugins/custom/redact.lua` / `redact_lib.lua` contain no `ner` references (grep: no match) |
| FR-3.2 token merge | Not implemented | no NER merge logic in `plugins/custom/` |
| NFR-1.x logging/metrics/mTLS | Not implemented | no sidecar code exists |
| Deployment unit (compose/systemd) | Not implemented | no `ner-engine` service in deployment configs or `res/` |
| Tests | Not implemented | no `tests/**` referencing NER |
