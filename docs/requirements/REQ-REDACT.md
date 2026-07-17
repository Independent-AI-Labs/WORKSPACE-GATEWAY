# REQ-REDACT: PII Redaction Plugin

**Date:** 2026-07-17
**Status:** Active
**Type:** Requirements
**Specification:** [SPEC-REDACT](../specifications/SPEC-REDACT.md)

> Mandates in-process PII detection and anonymization on LLM relay routes via the
> `redact` APISIX plugin: regex + dictionary matching with Luhn false-positive
> suppression, per-request redaction-token minting, response re-hydration, and
> fail-closed error posture. The single source of truth for patterns is
> `conf/redact-patterns.json`. Explicitly excluded: the v2 NER sidecar (separate
> Draft specification), per-tenant dictionaries, and multi-modal image scanning.

---

**Cross-references:**
- [SPEC-REDACT](../specifications/SPEC-REDACT.md): companion specification
- [`plugins/custom/redact.lua`](../../plugins/custom/redact.lua): APISIX plugin phases
- [`plugins/custom/redact_lib.lua`](../../plugins/custom/redact_lib.lua): pure detection/restore library
- [`conf/redact-patterns.json`](../../conf/redact-patterns.json): pattern and dictionary definitions

---

## 1. Purpose & Scope

### 1.1 Purpose

Ensure that PII (emails, SSNs, credit cards, API keys, phone numbers, JWTs, and
configured dictionary terms) sent through gateway relay routes is replaced with
deterministic redaction tokens before reaching upstream LLM providers, and that
the original values are restored in the client-facing response.

### 1.2 Scope

**This document OWNS the requirements for:**
- Pattern-based and dictionary-based PII detection in request bodies
- Luhn validation for credit-card false-positive suppression
- Redaction token minting and per-request token mapping
- Response re-hydration (buffer and passthrough streaming modes)
- Failure-mode behavior (`on_error` closed/open)

**This document DOES NOT:**
- Specify the optional NER sidecar (v2, separate Draft spec)
- Define usage/billing telemetry (owned by `sse-usage`)
- Cover per-tenant pattern files (not implemented)

### 1.3 Terminology

| Term | Definition |
|------|------------|
| Redaction token | ASCII token `[KIND_N]` substituted for a PII match (e.g. `[EMAIL_1]`) |
| Token map | Per-request Lua table mapping redaction tokens to original strings |
| Re-hydration | Restoring original PII values into the upstream response before it reaches the client |
| Patterns file | `conf/redact-patterns.json`; regex list + dictionary list |
| `redact_state` | nginx shared dict used to cache decoded patterns (60s TTL) |

## 2. Functional Requirements

### FR-1: Detection

| ID | Requirement |
|----|-------------|
| FR-1.1 | The plugin MUST load regex and dictionary patterns from a JSON patterns file (`conf/redact-patterns.json`, in-container path `/etc/apisix/redact-patterns.json`). |
| FR-1.2 | The plugin MUST match regex patterns via `ngx.re` (PCRE) with options `ijo` (case-insensitive, JIT, single-match-per-call ovector mode). |
| FR-1.3 | Dictionary entries MUST be combined into a single PCRE alternation with regex metacharacters escaped. |
| FR-1.4 | Patterns MUST be cached in the `redact_state` shared dict with a 60-second TTL; reload occurs on cache expiry. |
| FR-1.5 | Matches on patterns with `luhn_check: true` MUST be discarded unless the candidate string passes Luhn validation. |
| FR-1.6 | Patterns with `kind: ipv4` MUST be skipped unless `redact_ips` is true. (The shipped patterns file contains no `ipv4` pattern; the gate is latent.) |

### FR-2: Redaction & Token Minting

| ID | Requirement |
|----|-------------|
| FR-2.1 | Each detected PII instance MUST be replaced with a token of the form `[KIND_N]`, where KIND is the uppercased pattern kind and N is a per-request counter. |
| FR-2.2 | Dictionary matches MUST use the token form `[DICTIONARY_N]`. |
| FR-2.3 | The plugin MUST stash the token map in the per-request ctx (`ctx.redact_token_map`) and set `ctx.redact_active` only when at least one token was minted. |
| FR-2.4 | Both string `content` and multi-modal `content[]` parts with a `text` field MUST be redacted. |
| FR-2.5 | The request body MUST be rewritten with the redacted JSON before proxying upstream. |

### FR-3: Re-hydration

| ID | Requirement |
|----|-------------|
| FR-3.1 | In `body_filter`, the plugin MUST buffer response chunks until EOF and restore tokens in a single pass (no cosocket I/O is permitted in this phase). |
| FR-3.2 | For non-streaming responses, the plugin SHOULD parse the JSON body and restore within `choices[].message.content`, else whole-body substitution on parse failure. |
| FR-3.3 | For streaming (SSE) responses in default `buffer` mode, the plugin MUST substitute across the whole concatenated buffer on EOF. |
| FR-3.4 | Restoration MUST escape Lua pattern metacharacters in tokens and escape `%` in original replacement strings to prevent double-substitution. |
| FR-3.5 | When any redaction occurred, `header_filter` MUST clear `Content-Length` (forcing chunked transfer) and set `X-Redact-Active: 1`. |

### FR-4: Streaming Modes

| ID | Requirement |
|----|-------------|
| FR-4.1 | `stream_mode: reject` MUST return HTTP 400 when the request body contains `"stream": true`. |
| FR-4.2 | `stream_mode: buffer` (default) MUST buffer the SSE stream to EOF and emit the restored body as a single chunk. |
| FR-4.3 | `stream_mode: passthrough` MUST forward chunks unmodified, leaking redaction tokens to the client; it MUST NOT be the default. |

### FR-5: Failure Modes

| ID | Requirement |
|----|-------------|
| FR-5.1 | With `on_error: closed` (default), failure to load the patterns file MUST return HTTP 503. |
| FR-5.2 | With `on_error: open`, pattern-load failure MUST pass the request through unredacted and log an error. |
| FR-5.3 | A non-chat-shaped body (unparseable JSON or missing `messages`) MUST pass through unredacted and set `X-Redact-Error: non-chat-body`. |
| FR-5.4 | Failure to re-encode the redacted request body MUST return HTTP 503 (`closed`) or pass the original body through (`open`). |
| FR-5.5 | A `ngx.re.gsub` error on a single pattern MUST be logged and MUST NOT abort processing of remaining patterns. |

### FR-6: Observability

| ID | Requirement |
|----|-------------|
| FR-6.1 | In `log`, the plugin MUST populate `ctx.redact_log` with `active`, `token_count`, and `stream` for downstream serialization by `http-logger`. |

## 3. Non-Functional Requirements

| ID | Requirement |
|----|-------------|
| NFR-1.1 | Detection MUST run in-process (no sidecar/IPC on the hot path). |
| NFR-1.2 | Pattern matching SHOULD be sub-millisecond per kB via PCRE C bindings. |
| NFR-1.3 | The plugin MUST run at priority 2500 (after auth, before `ai-proxy`-family plugins). |

## 4. Constraints

| ID | Constraint | Source |
|----|------------|--------|
| C-1 | Patterns file is JSON (cjson bundled with OpenResty; YAML parser not guaranteed) | legacy redact spec §13 |
| C-2 | No cosocket use in `body_filter`; restore is local string substitution only | OpenResty phase semantics |
| C-3 | `on_error=closed` is the production posture | workspace AGENTS.md Rule 13 |

## 5. Assumptions

| ID | Assumption |
|----|------------|
| A-1 | Request/response bodies are OpenAI chat-completion shaped. |
| A-2 | Redaction tokens are fixed ASCII and cannot be split across SSE frames in a way that survives whole-buffer substitution. |

## 6. Open Questions

None. (Resolved: JSON patterns format; shared-dict 60s cache instead of per-request mtime checks; global single patterns file for v1; PCRE alternation over Aho-Corasick until dictionary size demands it.)

## 7. Verification Matrix

| # | Test | Maps to |
|---|------|---------|
| V1 | [`tests/lua/test_redact_lib.lua`](../../tests/lua/test_redact_lib.lua): unit tests for redact/restore/Luhn | FR-1.5, FR-2.x, FR-3.4 |
| V2 | [`tests/config/test_patterns_json.sh`](../../tests/config/test_patterns_json.sh): patterns file validity | FR-1.1 |
| V3 | Manual/integration: stream-mode matrix (reject 400 / buffer single-chunk / passthrough) | FR-4.x |

## 8. Implementation Status

| Item | Status | Evidence |
|------|--------|----------|
| FR-1.1 patterns loading | Implemented | `redact_lib.load_patterns` in plugins/custom/redact_lib.lua:21 |
| FR-1.4 shared-dict cache (60s) | Implemented | plugins/custom/redact.lua:44-74 |
| FR-1.5 Luhn check | Implemented | plugins/custom/redact_lib.lua:5-19 |
| FR-1.6 ipv4 gate | Implemented (latent; no ipv4 pattern shipped) | plugins/custom/redact_lib.lua:49 |
| FR-2.x token minting + ctx stash | Implemented | plugins/custom/redact_lib.lua:45-88, redact.lua:101-137 |
| FR-3.x re-hydration | Implemented | plugins/custom/redact.lua:146-185 |
| FR-4.x stream modes | Implemented | plugins/custom/redact.lua:97-99, 151-153 |
| FR-5.x fail modes | Implemented | plugins/custom/redact.lua:75-81, 87-95, 122-129 |
| FR-6.1 log metadata | Implemented | plugins/custom/redact.lua:187-194 |
| NER sidecar (v2) | Not implemented | No `ner_sidecar_url` in plugin schema; separate Draft spec |
