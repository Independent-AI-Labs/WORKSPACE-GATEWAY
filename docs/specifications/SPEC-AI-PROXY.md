# SPEC-AI-PROXY: Native AI Protocol Normalization  -  Audit and Decision

**Date:** 2026-09-23
**Status:** Draft (Not Adopted)
**Type:** Specification
**Requirements:** [REQ-AI-PROXY](../requirements/REQ-AI-PROXY.md)

> Detailed record of the 2026-09 duplication audit comparing the gateway's
> custom plugins against APISIX 3.18 native plugins, with focus on `ai-proxy` /
> `ai-protocols` / `ai-transport`. Concludes: **not adopted**; the only
> unambiguous code-level duplication is the SSE token-extraction layer in
> `sse_usage_lib.lua`, kept deliberately because native passthrough provides no
> usage.

---

**Cross-references:**
- [REQ-AI-PROXY](../requirements/REQ-AI-PROXY.md): decision contract
- [SPEC-BILLING-TELEMETRY](SPEC-BILLING-TELEMETRY.md): `sse-usage` telemetry
- [SPEC-COST-CALC](SPEC-COST-CALC.md) / [SPEC-PROVIDER-SYNC](SPEC-PROVIDER-SYNC.md): custom pricing/catalog
- [CUSTOM-PLUGINS](../architecture/CUSTOM-PLUGINS.md): custom plugin inventory
- [BUILTIN-PLUGINS](../architecture/BUILTIN-PLUGINS.md): native plugin usage

---

## 1. Overview

`ai-proxy.lua` (84 lines) is a coordinator over `ai-protocols/*`. It detects the
client protocol, converts it to an internal canonical format that **is OpenAI
Chat Completions**, selects a provider, injects provider auth (`ai-providers/*`,
incl. SigV4), rewrites the model, streams SSE (`ai-transport/sse.lua`), and
extracts token usage for the parsed protocols. There is **no standalone native
"usage" plugin**  -  extraction is bundled into `ai-proxy`.

## 2. Detection and Adapters

| Adapter | Role |
|---------|------|
| `openai-chat` | Default canonical; injects `stream_options.include_usage`; parses usage |
| `openai-responses` | Convert to canonical |
| `openai-embeddings` | Convert to canonical |
| `anthropic-messages` | Convert to canonical |
| `bedrock-converse` | Convert to canonical |
| `passthrough` | Catch-all; forwards; **`extract_usage` returns nil, `parse_sse_event` returns skip** |

Detection order: bedrock, anthropic, responses, chat, embeddings, passthrough.

## 3. Native Capability vs Gateway Feature

| Capability | Native `ai-proxy` | Gateway (custom) |
|------------|-------------------|------------------|
| Protocol normalization | Yes (canonical = OpenAI Chat) | No  -  passthrough per provider |
| Provider auth injection | Yes (static config) | `key-resolver` + OpenBao (dynamic) |
| SSE reassembly | Yes (`ai-transport/sse.lua`) | Yes (`sse_usage_lib`) |
| Token usage extraction | Yes for parsed protocols; **no in passthrough** | Yes (`sse-usage`) |
| Cost / pricing | No | Yes (`cost_calc`, `provider-sync*`) |
| Model catalog | No | Yes (`model_registry`, `provider-sync*`) |
| Upstream key pool rotation | No | Yes (`key-resolver`, `upstream_pool_lib`) |
| PII redact + restore | No (`data-mask` masks for logs only) | Yes (`redact`) |
| Typed ClickHouse aggregation | No (`clickhouse-logger` is schema-less) | Yes (`sse-usage` + `conf/sql`) |

## 4. System Diagram (current vs native)

```
CURRENT (passthrough)
  Client --provider-native--> APISIX proxy-rewrite --> Provider
                                   | sse-usage (extract usage by protocol parser)
                                   v ClickHouse (typed, cost)

NATIVE (ai-proxy)
  Client --any protocol--> ai-proxy --canonical--> ai-protocols --convert-->
                                   | usage extracted (known protocols only)
                                   v provider  (passthrough => no usage)
```

## 5. Duplication Detail (audit finding)

`ai-protocols/openai-chat.lua::parse_sse_event` already:

- injects `stream_options.include_usage` (`prepare_outgoing_request`),
- decodes SSE `data:` frames and `[DONE]`,
- extracts `prompt_tokens`, `completion_tokens`, `total_tokens`,
  `cache_read_input_tokens`, `cache_creation_input_tokens`, `reasoning_tokens`.

`sse_usage_lib.lua` (227 lines) implements the same extraction for the
passthrough path. This is the **only unambiguous code-level duplication** found
in the 2026-09 audit. It is accepted because:

1. native extraction is unavailable in passthrough mode, and
2. adopting `ai-proxy` would change the data-plane wire format (product decision).

Other audit results (partial/transport only, not adopted): `data-mask` vs
`redact` (log-phase masking, no restore), `clickhouse-logger` vs `sse-usage`
schema-less transport, `limit-count`/`ai-rate-limiting` vs inline RPM/quota.

## 6. Adoption Path (if reversed)

If normalization is ever required:

1. Register `ai-proxy` and configure providers per route.
2. Delete the custom protocol/usage path (`sse_usage_lib` usage parsing).
3. Keep `key-resolver` for dynamic OpenBao credentials (native static `api_key`
   is insufficient, FR-1.2).
4. Keep `cost_calc`/`provider-sync`/`redact`/pool logic (no native equivalent).
5. Re-run the audit to confirm no residual duplication.

## 7. File Map

| File | Purpose | Key Changes |
|------|---------|-------------|
| `docs/requirements/REQ-AI-PROXY.md`, `docs/specifications/SPEC-AI-PROXY.md` | decision record | new |
| `plugins/custom/sse-usage.lua`, `plugins/custom/sse_usage_lib.lua` | passthrough usage extraction | unchanged; documented as owning the duplicate |

## 8. Implementation Status

| Component | Status | Evidence |
|-----------|--------|----------|
| `ai-proxy` adoption | Not adopted | no `ai-proxy` in `conf/` |
| Duplication documented | Done | §5 here, REQ-AI-PROXY §5 |
| Shared SSE reader | Not pursued |  -  |
