# REQ-PROVIDER-ZAI: Z.ai Provider (GLM Coding Plan Own-Key Passthrough)

**Date:** 2026-08-29
**Status:** Active
**Type:** Requirements
**Specification:** [SPEC-PROVIDER-ZAI](../specifications/SPEC-PROVIDER-ZAI.md)

> Mandates the Z.ai (Zhipu BigModel international) GLM integration in own-key
> mode only: two passthrough relay routes to the GLM Coding Plan endpoint
> `api.z.ai/api/coding/paas/v4`, where the client's own Z.ai API key is
> forwarded as-is. Explicitly excluded: gateway-managed OAuth (Z.ai offers
> none; API keys are the only credential), virtual-key/federated mode, the
> Anthropic (`/api/anthropic`) and OpenAI Responses (`/api/v1`) protocol
> endpoints, and the general PAYG endpoint `/api/paas/v4`.

---

**Cross-references:**
- [SPEC-PROVIDER-ZAI](../specifications/SPEC-PROVIDER-ZAI.md): companion specification
- [REQ-GATEWAY-CORE](REQ-GATEWAY-CORE.md): route/upstream baseline this provider extends
- [REQ-PROVIDER-KIMI](REQ-PROVIDER-KIMI.md): implemented analog provider with OAuth/federated modes
- [`conf/apisix.yaml`](../../conf/apisix.yaml) + [`conf/apisix.yaml.j2`](../../conf/apisix.yaml.j2): 2 `relay-zai-key*` routes
- [`conf/providers/workspace-gw-zai-api-key.yaml`](../../conf/providers/workspace-gw-zai-api-key.yaml): provider definition

---

## 1. Purpose & Scope

### 1.1 Purpose

Provide OpenAI-compatible access to Z.ai GLM models (glm-5.x, glm-4.5-air,
etc.) through the gateway in bring-your-own-key mode: the client holds a Z.ai
API key (GLM Coding Plan subscription or PAYG balance), the gateway adds zero
credential logic and proxies transparently.

### 1.2 Scope

**This document OWNS the requirements for:**
- The 2 Z.ai relay routes and their passthrough auth mode
- The OpenCode provider definition `workspace-gw-zai-api-key`

**This document DOES NOT:**
- Define gateway-held credentials for Z.ai (none exist; own-key only)
- Specify model catalog/pricing sync internals (owned by REQ-PROVIDER-SYNC)
- Cover the Anthropic-protocol or Responses-protocol Z.ai endpoints

### 1.3 Terminology

| Term | Definition |
|------|------------|
| Own-key mode | Client sends its own Z.ai API key; gateway passes it through untouched |
| Coding Plan endpoint | `https://api.z.ai/api/coding/paas/v4`: subscription-quota billing, OpenAI Chat Completions protocol |
| General endpoint | `https://api.z.ai/api/paas/v4`: PAYG balance billing; NOT used by this provider |

## 2. Functional Requirements

### FR-1: Routes

| ID | Requirement |
|----|-------------|
| FR-1.1 | The gateway SHALL expose 2 Z.ai routes: `relay-zai-key` (`/zai-key/*`) and `relay-zai-key-v1` (`/zai-key/v1/*`). |
| FR-1.2 | Both routes MUST proxy to `api.z.ai:443` over HTTPS and rewrite the path to `/api/coding/paas/v4/*` (Coding Plan endpoint; NOT the general `/api/paas/v4`). |
| FR-1.3 | Both routes MUST attach neither `kimi-auth` nor `key-resolver`; the client `Authorization: Bearer <zai-key>` header MUST be forwarded as-is. |
| FR-1.4 | Both routes MUST attach the common relay plugin stack (`key-meta`, `limit-count` 100/60s keyed on `http_x_key_hash`, `prometheus`, `request-id`, `http-logger`, `proxy-buffering` disabled, `redact`, `sse-usage`). |
| FR-1.5 | `/zai-key/v1/*` exists so OpenAI-SDK-style base URLs (`.../zai-key/v1`) work without double-`v1` paths. |

### FR-2: OpenCode Provider Mapping

| ID | Requirement |
|----|-------------|
| FR-2.1 | One OpenCode provider id MUST exist: `workspace-gw-zai-api-key` (`/zai-key`, auth `api_key`). |
| FR-2.2 | It MUST source models from models.dev provider `zai` with `strip_prefix: z-ai/` + `lowercase` normalization and `pricing.source.type: models_dev`, `pricing.source.provider: zai`. |

## 3. Non-Functional Requirements

| ID | Requirement |
|----|-------------|
| NFR-1.1 | The upstream MUST be HTTPS on `api.z.ai` (TLS-verified by the data plane default). |
| NFR-1.2 | Client API keys MUST NOT be logged (redact plugin active on both routes). |
| NFR-1.3 | Billing telemetry (`sse-usage`) MUST work unchanged (GLM endpoints are OpenAI Chat Completions compatible, SSE usage included). |

## 4. Constraints

| ID | Constraint | Source |
|----|------------|--------|
| C-1 | Own-key passthrough only; no gateway-managed auth | Z.ai upstream contract: static API keys, no OAuth/device flow (verified 2026-08-29, docs.z.ai) |
| C-2 | Coding endpoint `/api/coding/paas/v4`, not interchangeable with `/api/paas/v4` | docs.z.ai devpack/quick-start + tool-integration guides: wrong endpoint cannot use Coding Plan quota |
| C-3 | Chat Completions protocol only; Responses (`/api/v1`) and Anthropic (`/api/anthropic`) endpoints out of scope | docs.z.ai devpack endpoint table |

## 5. Assumptions

| ID | Assumption |
|----|------------|
| A-1 | GLM Coding Plan endpoints are fully OpenAI Chat-Completions-compatible; `sse-usage`/`cost_calc` need no Z.ai-specific changes. |
| A-2 | models.dev provider `zai` covers the GLM model set and pricing (PAYG rates; subscription quota usage is priced at PAYG-equivalent by the existing `zai-coding-plan`→`zai` shadow map in stats migration). |

## 6. Open Questions

None. (Resolved: own-key mode only, coding endpoint chosen over general.)

## 7. Verification Matrix

| # | Test | Maps to |
|---|------|---------|
| V1 | [`tests/config/test_apisix_yaml.sh`](../../tests/config/test_apisix_yaml.sh) | FR-1.1-FR-1.4 (route ids, URIs, node, no auth plugin, rewrite) |
| V2 | [`tests/config/test_apisix_yaml_render.sh`](../../tests/config/test_apisix_yaml_render.sh) | .j2/.yaml drift (Z.ai routes are untemplated and stable across renders) |

## 8. Implementation Status

| Item | Status | Evidence |
|------|--------|----------|
| FR-1.x 2 routes | Implemented | conf/apisix.yaml + apisix.yaml.j2 `relay-zai-key*` |
| FR-2.x provider YAML | Implemented | conf/providers/workspace-gw-zai-api-key.yaml |
