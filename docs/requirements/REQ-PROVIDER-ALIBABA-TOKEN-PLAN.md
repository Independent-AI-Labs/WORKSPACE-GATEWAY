# REQ-PROVIDER-ALIBABA-TOKEN-PLAN: Alibaba Cloud Token Plan (Own-Key Passthrough)

**Date:** 2026-09-20
**Status:** Draft
**Type:** Requirements
**Specification:** [SPEC-PROVIDER-ALIBABA-TOKEN-PLAN](../specifications/SPEC-PROVIDER-ALIBABA-TOKEN-PLAN.md)
**Research:** [RES-PROVIDER-ALIBABA-TOKEN-PLAN](../research/RES-PROVIDER-ALIBABA-TOKEN-PLAN.md)

> Mandates the Alibaba Cloud Model Studio (Bailian) Token Plan integration in
> own-key mode only: bare passthrough relay routes to the two Token Plan
> endpoint hosts (`token-plan.ap-southeast-1.maas.aliyuncs.com` for the
> International/Singapore plan and `token-plan.cn-beijing.maas.aliyuncs.com`
> for the China/Beijing plan), where the client's own `sk-sp-…` plan key is
> forwarded as-is and both the OpenAI-compatible and Anthropic-compatible
> protocols pass through verbatim. Explicitly excluded: gateway-managed
> OAuth or device login (the Token Plan has no such flow), virtual-key or
> federated mode, the separate Coding Plan family (`coding*.dashscope.aliyuncs.com`),
> the pay-as-you-go and savings-plan `sk-` families, and the console's
> `o1_` obfuscated key form (decoding is the client's responsibility).

---

**Cross-references:**
- [SPEC-PROVIDER-ALIBABA-TOKEN-PLAN](../specifications/SPEC-PROVIDER-ALIBABA-TOKEN-PLAN.md): companion specification
- [RES-PROVIDER-ALIBABA-TOKEN-PLAN](../research/RES-PROVIDER-ALIBABA-TOKEN-PLAN.md): endpoint catalog and verification
- [REQ-PROVIDER-ZAI](REQ-PROVIDER-ZAI.md): own-key passthrough provider pattern
- [REQ-PROVIDER-ANTHROPIC](REQ-PROVIDER-ANTHROPIC.md): bare-relay route pattern
- [`conf/apisix.yaml`](../../conf/apisix.yaml) + [`conf/apisix.yaml.j2`](../../conf/apisix.yaml.j2): relay routes
- [`conf/providers/`](../../conf/providers): provider definitions

---

## 1. Purpose & Scope

### 1.1 Purpose

Provide transparent access to Alibaba Cloud Token Plan models (Qwen, GLM,
DeepSeek, and others) through the gateway in bring-your-own-key mode: the
client holds an `sk-sp-…` plan key, the gateway adds zero credential logic,
and both supported protocols (OpenAI-compatible and Anthropic-compatible)
work without client-side gateway configuration beyond a base URL.

### 1.2 Scope

**This document OWNS the requirements for:**
- The 2 Token Plan relay routes (`/token-plan/*` International and
  `/token-plan-cn/*` China) and their passthrough auth mode
- The 2 OpenCode provider definitions
  (`workspace-gw-alibaba-token-plan-passthrough`,
  `workspace-gw-alibaba-token-plan-cn-passthrough`)
- Path-transparent relaying of both wire protocols

**This document DOES NOT:**
- Define gateway-held credentials (own-key only)
- Cover the Coding Plan, pay-as-you-go, or savings-plan families
- Implement the `o1_` console-key decoder (client-side concern)
- Specify model catalog/pricing sync internals (owned by REQ-PROVIDER-SYNC)

### 1.3 Terminology

| Term | Definition |
|----------|------------|
| Own-key mode | Client sends its own `sk-sp-…` plan key; gateway forwards it untouched |
| Token Plan endpoint | The two `token-plan.{region}.maas.aliyuncs.com` hosts; Credits billing |
| Plan key | `sk-sp-…` credential from the subscription page; shared prefix with Coding Plan |
| Protocol passthrough | `/compatible-mode/v1` and `/apps/anthropic` paths relay unchanged |
| `o1_` key | Console-obfuscated token; not accepted by the API, client decodes locally |

## 2. Functional Requirements

### FR-1: Routes

| ID | Requirement |
|----|-------------|
| FR-1.1 | The gateway SHALL expose `relay-alibaba-token-plan` (`/token-plan/*`) proxying to `token-plan.ap-southeast-1.maas.aliyuncs.com:443` (International/Singapore plan) over HTTPS with path rewrite `^/token-plan/(.*)` to `/$1`. |
| FR-1.2 | The gateway SHALL expose `relay-alibaba-token-plan-cn` (`/token-plan-cn/*`) proxying to `token-plan.cn-beijing.maas.aliyuncs.com:443` (China/Beijing plan) over HTTPS with path rewrite `^/token-plan-cn/(.*)` to `/$1`. |
| FR-1.3 | Both routes MUST be path-transparent: the client's `/apps/anthropic/v1/messages` and `/compatible-mode/v1/chat/completions` paths, query strings, and request bodies MUST reach upstream unmodified except for the route-prefix strip. |
| FR-1.4 | Both routes MUST NOT attach `provider-oauth` or `key-resolver`; the client `Authorization` header MUST be forwarded as-is. |
| FR-1.5 | Both routes MUST force `accept-encoding: identity` upstream so SSE usage telemetry reads plaintext. |
| FR-1.6 | Both routes MUST attach the common relay plugin stack (`key-meta`, `limit-count` 100/60s keyed on `http_x_key_hash`, `prometheus`, `request-id`, `http-logger`, `proxy-buffering` disabled, `redact`, `sse-usage`). |
| FR-1.7 | The two route blocks MUST be committed identically in `conf/apisix.yaml` and `conf/apisix.yaml.j2`. |

### FR-2: Protocols

| ID | Requirement |
|----|-------------|
| FR-2.1 | The Anthropic-compatible path (`/apps/anthropic/...`) MUST work for Claude Code (`base=/apps/anthropic`) and OpenCode (`base=/apps/anthropic/v1`). |
| FR-2.2 | The OpenAI-compatible path (`/compatible-mode/v1/...`) MUST work for OpenAI-SDK-style clients. |
| FR-2.3 | The gateway MUST NOT inject protocol-specific headers or rewrite paths beyond the prefix strip. |

### FR-3: Provider definitions & models

| ID | Requirement |
|----|-------------|
| FR-3.1 | Two provider files SHALL be provisioned: `workspace-gw-alibaba-token-plan-passthrough` (route `/token-plan`, label `Alibaba Cloud Token Plan`) and `workspace-gw-alibaba-token-plan-cn-passthrough` (route `/token-plan-cn`, label `Alibaba Cloud Token Plan (China)`), both auth type `passthrough`. |
| FR-3.2 | The model catalog SHALL include the coding/text models observed on the live endpoint (`qwen3.8-max`, `qwen3.8-flash`, `qwen3.7-max`, `qwen3.7-plus`, `qwen3.6-flash`, `glm-5.3`, `glm-5.2`, `deepseek-v4-pro`, `deepseek-v4.1-flash`, `deepseek-v4-flash-0731`); ids MUST NOT be remapped. Image/audio models (`wan2.7-image*`, `qwen-audio-*`) SHALL be omitted from the text provider. |
| FR-3.3 | Pricing SHALL use `pricing.source.type: models_dev` with `missing_policy: unknown`; the plan is Credits-based and token pricing is indicative for dashboards only. |
| FR-3.4 | An unknown model id returned by the client MUST pass through without a gateway error rather than being rejected by the provider definition. |

### FR-4: Security

| ID | Requirement |
|----|-------------|
| FR-4.1 | Plan keys MUST NOT be logged; the redact pipeline MUST remain active on both routes. |
| FR-4.2 | The gateway MUST NOT custody, log, decode, or rewrite any credential on these routes. |
| FR-4.3 | Rate limits and key hashing MUST apply exactly as on existing provider routes. |

## 3. Non-Functional Requirements

| ID | Requirement |
|----|-------------|
| NFR-1 | Passthrough streaming MUST add no measurable first-byte latency beyond transport (proxy-buffering disabled). |
| NFR-2 | Upstream hosts and the model list MUST live in per-route config and provider YAML; an endpoint change MUST NOT require plugin code. |
| NFR-3 | Both routes MUST remain under the standard route plugin budget and file size limits of the repo. |

## 4. Constraints

| ID | Constraint | Source |
|----|------------|--------|
| C-1 | Own-key passthrough only; no OAuth/device flow exists upstream | RES sections 4, 8 |
| C-2 | The plan key is bound to its endpoint family; Token Plan key on `coding*` returns 401 | RES sections 5, 6 |
| C-3 | `sk-sp-` is shared with Coding Plan; only the host disambiguates | RES section 1 |
| C-4 | Plan is licensed for interactive coding tools only | RES section 7; Token/Coding Plan docs |
| C-5 | Model list is console-defined and unstable | RES section 3 |

## 5. Assumptions

| ID | Assumption |
|----|------------|
| A-1 | The Token Plan hosts are wire-compatible enough that `sse-usage`/`cost_calc` need no provider-specific parsing. |
| A-2 | Clients present the already-decoded `sk-sp-…` key, not the `o1_` console form. |

## 6. Open Questions

| ID | Question | Impact |
|----|----------|--------|
| OQ-1 | Exact CN model list (not queried; no CN key available). | CN provider model list may differ; both routes share the same YAML shape. |
| OQ-2 | Whether models.dev contains usable ids for `qwen3.8-*` / `deepseek-v4*` / `glm-5.3`. | Pricing may resolve to `unknown`. |

## 7. Verification Matrix

| # | Test | Maps to |
|---|------|---------|
| V1 | `tests/config/test_alibaba_token_plan_routes.sh` (new) | FR-1.1-FR-1.6 (route ids, URIs, nodes, no auth plugin, rewrite, identity encoding), FR-2.x (protocol paths) |
| V2 | `tests/config/test_apisix_yaml_render.sh` | FR-1.7 (.j2/.yaml drift) |
| V3 | `tests/config/test_provider_oauth_routes.sh` route-provider guard | FR-1.6 (route→provider map in `cost_calc`) |
| V4 | `tests/config/test_apisix_yaml.sh` route count | FR-1.1/FR-1.2 (exactly 2 new routes) |
| V5 | `tests/config/test_zai_provider.sh` per-provider loop | FR-3.1 (provider file schema) |

## 8. Implementation Status

| Item | Status | Evidence |
|------|--------|----------|
| FR-1.x 2 routes | Implemented | conf/apisix.yaml + conf/apisix.yaml.j2 (`relay-alibaba-token-plan`, `relay-alibaba-token-plan-cn`); seeded live via `res/scripts/seed-routes.sh` (18/18 routes) |
| FR-3.x provider YAMLs | Implemented | conf/providers/workspace-gw-alibaba-token-plan{-cn,}-passthrough.yaml; provider sync reports 28 enriched models each |
| Route-provider map | Implemented | plugins/custom/cost_calc.lua `ROUTE_PROVIDERS` (single source, required by sse-usage.lua); activated via a clean `apisix reload` (no container restart) - usage_log `provider_id` now resolves to `workspace-gw-alibaba-token-plan-passthrough` |
| FR-4.x security (no credential custody) | Implemented | redact pipeline active on both routes (SPEC-REDACT); no credential logged or rewritten |
| Config tests | Implemented | tests/config/test_alibaba_token_plan_routes.sh; `test_apisix_yaml.sh` (18 routes) and `test_apisix_yaml_render.sh` (11/11) pass |
| E2E live passthrough | Verified | `POST /token-plan/compatible-mode/v1/chat/completions` (200) and `/token-plan/apps/anthropic/v1/messages` (200); SSE stream 200; `/token-plan-cn` forwards to CN and returns upstream 401 without a CN key; usage_log rows show qwen3.8-max with `pricing_source=models_dev` |
