# REQ-AI-PROXY: Native AI Protocol Normalization (Not Adopted)

**Date:** 2026-09-23
**Status:** Draft (Not Adopted)
**Type:** Requirements
**Specification:** [SPEC-AI-PROXY](../specifications/SPEC-AI-PROXY.md)

> **Decision:** the gateway does **not** adopt APISIX `ai-proxy` /
> `ai-protocols`. The data plane stays provider-passthrough
> (`proxy-rewrite` per provider) with a custom `sse-usage` telemetry layer.
> This document records what the native plugin offers, why it was not adopted,
> and  -  required by the 2026-09 duplication audit  -  the one genuine
> code/feature duplication that decision creates (SSE token extraction).
> Nothing here is implemented; the requirements below describe native
> capabilities, not gateway commitments.
>
> This is the successor to the `ai-proxy` half of
> [REQ-ENTERPRISE-AUTH](REQ-ENTERPRISE-AUTH.md) (Retired).

---

**Cross-references:**
- [SPEC-AI-PROXY](../specifications/SPEC-AI-PROXY.md): companion specification and audit detail
- [REQ-BILLING-TELEMETRY](REQ-BILLING-TELEMETRY.md): `sse-usage` telemetry contract the duplicate lives in
- [REQ-COST-CALC](REQ-COST-CALC.md): pricing that `ai-proxy` does not provide
- [REQ-PROVIDER-SYNC](REQ-PROVIDER-SYNC.md): catalog/pricing owned entirely by custom code
- [SPEC-PROVIDER-OPENAI](../specifications/SPEC-PROVIDER-OPENAI.md) / [SPEC-PROVIDER-ANTHROPIC](../specifications/SPEC-PROVIDER-ANTHROPIC.md): passthrough routes
- [`plugins/custom/sse-usage.lua`](../../plugins/custom/sse-usage.lua), [`plugins/custom/sse_usage_lib.lua`](../../plugins/custom/sse_usage_lib.lua): the duplicated extraction layer

---

## 1. Purpose & Scope

### 1.1 Purpose

Provide a durable, auditable rationale for keeping provider-passthrough routing
instead of adopting the native `ai-proxy` plugin, and record the resulting
duplication so it is a known, owned decision rather than unrecorded reinvention.

### 1.2 Scope

**This document OWNS:**
- The adopt/not-adopt decision for `ai-proxy` / `ai-protocols` / `ai-transport`
- The documented duplication: `sse_usage_lib.lua` token extraction vs
  `ai-protocols/openai-chat.lua`
- The boundary between native AI plugins and gateway-owned features

**This document DOES NOT:**
- Define passthrough route config (SPEC-PROVIDER-*)
- Define the telemetry schema (`sse-usage` writes it; SPEC-BILLING-TELEMETRY)
- Define cost/pricing (REQ-COST-CALC / REQ-PROVIDER-SYNC)
- Claim any native plugin is deployed

### 1.3 Terminology

| Term | Definition |
|------|------------|
| Canonical format | Internal wire shape used by `ai-proxy`; it is **OpenAI Chat Completions** |
| Protocol adapter | One of `openai-chat`, `openai-responses`, `openai-embeddings`, `anthropic-messages`, `bedrock-converse`, `passthrough` |
| Passthrough adapter | Native catch-all that forwards without transformation; explicitly returns no usage |
| Duplicate | Our token-extraction logic mirroring `ai-protocols`' SSE parsing |

## 2. Functional Requirements

These describe native `ai-proxy` capabilities (FR-N) and the conditions that
would apply only if the decision is reversed (FR-1).

| ID | Requirement |
|----|-------------|
| FR-N.1 | Native `ai-proxy` detects the client protocol (order: bedrock, anthropic, responses, chat, embeddings, passthrough). |
| FR-N.2 | It converts client <-> canonical (OpenAI Chat) <-> upstream provider bidirectionally. |
| FR-N.3 | It injects provider auth (`ai-providers/*`, incl. AWS SigV4) and can rewrite model/endpoint. |
| FR-N.4 | It reassembles SSE and extracts token usage for parsed protocols. |
| FR-N.5 | It injects `stream_options.include_usage` for known protocols. |
| FR-N.6 | Its passthrough adapter **forfeits FR-N.4** (`extract_usage` returns nil). |
| FR-1.1 | If adopted, `ai-proxy` MUST replace custom protocol/usage handling rather than coexist with it. |
| FR-1.2 | Provider credentials MUST still be resolved dynamically from OpenBao via `key-resolver`; `ai-proxy`'s static `api_key` is insufficient. |
| FR-1.3 | Cost/pricing, model catalog, upstream key pooling, PII redaction, and ClickHouse business aggregation MUST remain gateway-owned (no native equivalent). |
| FR-1.4 | If passthrough mode is retained, usage extraction MUST come from `sse-usage` (native passthrough provides none). |

## 3. Non-Functional Requirements

| ID | Requirement |
|----|-------------|
| NFR-1.1 | No new custom code may re-implement native AI protocol parsing while this decision stands; the existing `sse_usage_lib` is grandfathered. |
| NFR-1.2 | Any future adoption MUST be a single coordinated change (disable the passthrough usage path in the same change). |
| NFR-1.3 | Auditability: this document MUST be updated if the decision changes. |

## 4. Constraints

| ID | Constraint | Source |
|----|------------|--------|
| C-1 | Native `ai-proxy` canonical format is OpenAI Chat, not provider-native | `ai-protocols/openai-chat.lua` |
| C-2 | Native passthrough adapter returns no usage | `ai-protocols/passthrough.lua` |
| C-3 | `ai-proxy` has no pricing/catalog/pool/redaction capability | plugin inventory (2026-09 audit) |
| C-4 | Routes are passthrough today; changing this is a product decision | SPEC-PROVIDER-* |

## 5. Assumptions

| ID | Assumption |
|----|------------|
| A-1 | APISIX 3.18.0 `ai-proxy` and adapters remain as audited (2026-09). |
| A-2 | Provider passthrough requirements do not change to require normalization. |

## 6. Open Questions

| Q | Resolution |
|---|------------|
| Would a thin shared SSE reader reduce duplication without adopting ai-proxy? | Not pursued; would still be custom code with no native ownership |
| Is there value in native protocol *conversion* (e.g. accept Anthropic-format on an OpenAI route)? | Product question; would reopen the decision |

## 7. Verification Matrix

| # | Test | Maps to |
|---|------|---------|
| V1 | `ai-proxy` is not registered/attached in `conf/` | Decision (FR-1.1) |
| V2 | `sse-usage` remains the sole usage-extraction path and is documented as owning the duplicate | FR-1.4 |
| V3 | No other custom plugin re-implements native AI parsing | NFR-1.1 |

## 8. Implementation Status

| Item | Status | Evidence |
|------|--------|----------|
| Adopt `ai-proxy` | **Not adopted** | no `ai-proxy` in `conf/` |
| Documented duplication (`sse_usage_lib` vs `ai-protocols/openai-chat`) | Accepted, owned | §2 FR-1.4 + SPEC-AI-PROXY §5 |
| Extract shared reader | Not pursued |  -  |
