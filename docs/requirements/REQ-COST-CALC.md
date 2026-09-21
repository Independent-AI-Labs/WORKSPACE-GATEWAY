# REQ-COST-CALC: Cost Calculation Module

**Date:** 2026-07-17
**Status:** Active
**Type:** Requirements
**Specification:** [SPEC-COST-CALC](../specifications/SPEC-COST-CALC.md)

> Mandates cost calculation behavior for [`plugins/custom/cost_calc.lua`](../../plugins/custom/cost_calc.lua): a read-only pricing consumer exposing `get_pricing`, `compute_cost`, `resolve_cost`; `provider-sync` (`provider_sync_pricing.lua`) is the single writer of provider-scoped `pricing:*` keys in the `gateway-cache` shared dict. Billed cost is resolved in exactly two steps: the provider's explicit `pricing.overrides` (the only manual price declaration), else models.dev (the pricing registry, ~99% of models). Upstream-reported per-response cost is **not** the billed cost - it is stored separately as reported-cost metadata. Unknown pricing yields cost 0 with `cost_source = unknown` and a logged warning - never a crash, never a guess.

---

**Cross-references:**
- [SPEC-COST-CALC](../specifications/SPEC-COST-CALC.md): companion specification
- [`plugins/custom/cost_calc.lua`](../../plugins/custom/cost_calc.lua): owns the module
- [`plugins/custom/provider_sync_pricing.lua`](../../plugins/custom/provider_sync_pricing.lua): sole `pricing:*` writer
- Earlier COST-CALC-LUA spec (head note v1.3 current; writer path sections removed, absorbed)
- [`tests/config/test_model_registry.sh`](../../tests/config/test_model_registry.sh): enforces the single-writer rule

---

## 1. Purpose & Scope

### 1.1 Purpose
Provide deterministic, auditable per-request USD cost for every usage row, resolved from the provider's explicit `pricing.overrides` first and models.dev second, and reporting `cost_source = unknown` explicitly when pricing is unavailable. Upstream-reported cost is recorded as separate metadata and never substituted for the billed cost.

### 1.2 Scope
**This document OWNS the requirements for:**
- The read-only consumer rule and single-writer rule for `pricing:*` keys
- Provider-scoped canonical pricing key derivation
- Cost math over input/output/cache/reasoning tokens
- Failure behavior on unknown pricing

**This document DOES NOT:**
- Define provider-sync catalog fetching (owned by provider-sync specs)
- Define token extraction (REQ-BILLING-TELEMETRY)
- Describe the removed writer path from the earlier COST-CALC-LUA spec

### 1.3 Terminology
| Term | Definition |
|------|------------|
| pricing:* key | JSON blob in shared dict `gateway-cache` under `pricing:<provider_id>:<canonical-model-id>` with numeric `input`, `output`, effective `cache_read`, `cache_write`, optional `reasoning` (per 1M tokens; a cache rate the source omits or zeroes is billed at the input rate) |
| Canonical model id | Output of `model_registry.canonical()` from `conf/model-registry.yaml` |
| cost_source | `provider_override` (price declared in the provider YAML `pricing.overrides`), `models_dev` (price resolved from the models.dev registry), `unknown` (no pricing) |
| models.dev | The pricing/metadata registry used for ~99% of prices. It is **not** a provider: it is consulted by canonical model id within the namespace the provider declares (`pricing.source.provider`), never scanned cross-provider. |
| reported_cost | Upstream-reported per-response cost (`usage.estimated_cost` / body `cost`), persisted as metadata only; it never determines the billed `cost` or `cost_source`. |

## 2. Functional Requirements

### FR-1: Read-Only Consumer
| ID | Requirement |
|----|-------------|
| FR-1.1 | `cost_calc` MUST be a pure Lua module, NOT a registered APISIX plugin: no schema, no priority, no phase bindings. |
| FR-1.2 | `cost_calc` MUST NOT write any `pricing:*` key. The ONLY writer MUST be `provider_sync_pricing.lua` (enforced by `tests/config/test_model_registry.sh`, which greps for `dict:set("pricing:"`). |
| FR-1.3 | `cost_calc` MUST NOT fetch models.dev or any remote pricing source itself. |
| FR-1.4 | The module MUST expose exactly the public functions `get_pricing(model_id, provider_id)`, `compute_cost(tokens, price)`, `resolve_cost(tokens, model_id, provider_id)` plus the `SOURCE_PROVIDER_OVERRIDE`/`SOURCE_MODELS_DEV`/`SOURCE_UNKNOWN` constants. |

### FR-2: Canonical Pricing Keys
| ID | Requirement |
|----|-------------|
| FR-2.1 | All pricing lookups MUST be keyed by provider id plus `model_registry.canonical(model_id)`; the module MUST contain no local key-normalization logic. |
| FR-2.2 | The shared dict MUST be `gateway-cache` with key prefix `pricing:`. |
| FR-2.3 | The module MUST be read-only: it never triggers a sync, never fetches, and treats an absent provider-scoped key as a miss. provider-sync warms the cache in `plugin.init()` and via `POST /gateway/providers/sync`. |

### FR-3: Cost Math
| ID | Requirement |
|----|-------------|
| FR-3.1 | `compute_cost` MUST compute: `max(pt - cached - cache_write, 0) * input / 1e6 + output_non_reasoning * output / 1e6 + cached * cache_read_rate / 1e6 + cache_write * cache_write_rate / 1e6 + reasoning * reasoning_rate / 1e6`, with negative components clamped to 0. |
| FR-3.2 | `reasoning_rate` MUST equal the `output` rate when the price has no `reasoning` field. |
| FR-3.3 | Cache pricing MUST be supported for both reads and writes; when no `cache_read` or `cache_write` rate is declared, the `input` rate MUST be used (never bill cache tokens free). |
| FR-3.4 | All token/rate values MUST be coerced with `tonumber(...) or 0`. |
| FR-3.5 | When `reasoning > completion_tokens` (a provider counting reasoning as a separate stream), `output_non_reasoning` MUST equal `completion_tokens` so reasoning is not subtracted twice. |
| FR-3.6 | A persistent, idempotent, non-destructive recalculation tool MUST be able to revalue historical rows using this same formula, provider-scoped, with a mandatory verified backup and an audit trail. It recomputes the billed `cost`/`cost_source` from the provider override or models.dev; the reported-cost metadata column is never modified. |

### FR-4: Failure Behavior
| ID | Requirement |
|----|-------------|
| FR-4.1 | `resolve_cost` MUST always derive the billed cost from the cached price record: provider `pricing.overrides` first (`cost_source = provider_override`), else models.dev (`cost_source = models_dev`). An upstream-reported cost MUST NOT be returned as the billed cost. |
| FR-4.2 | When no pricing resolves, `resolve_cost` MUST return `(0, "unknown")`  -  cost MUST NOT be fabricated from the upstream response, a metadata join, or another provider. |
| FR-4.3 | An unpriced provider/model MUST return `(0, "unknown")` as a plain miss. A cached price record whose provenance is neither `provider_override` nor `models_dev` MUST log an error (`core.log.error`) and return `(0, "unknown")` instead of billing with an unlabelable source. |
| FR-4.4 | A missing price table or a price table without numeric `input` MUST be treated as a miss. |
| FR-4.5 | `compute_cost`/`resolve_cost` (priced + unknown branches) MUST be loadable in plain LuaJIT without the nginx runtime (deferred requires), so unit tests run with zero dependency injection. |

## 3. Non-Functional Requirements
| ID | Requirement |
|----|-------------|
| NFR-1.1 | The pricing lookup MUST be an in-memory shared-dict read on the hot path. |
| NFR-1.2 | Cross-provider merging MUST NOT occur in any form: no "cheapest-wins", no alphabetical first-wins scan of the models.dev registry, no substitution with an unrelated provider's model entry. Each provider/model pair has an independent price record resolved solely from the provider's own override or its declared models.dev namespace. |

## 4. Constraints
| ID | Constraint | Source |
|----|-----------|--------|
| C-1 | Deployed flat to `/usr/local/apisix/apisix/plugins/cost_calc.lua`, required as `apisix.plugins.cost_calc` | cost_calc.lua header |
| C-2 | Single-writer rule enforced in CI | tests/config/test_model_registry.sh:113-116 |

## 5. Assumptions
| ID | Assumption |
|----|-----------|
| A-1 | provider-sync warms the pricing cache at startup (sse-usage `plugin.init`). |
| A-2 | Rates are USD per 1M tokens. |

## 6. Open Questions
| Q | A |
|---|---|
| Earlier writer path (`warmup`/`fetch_and_cache`/`normalize_key`)? | Removed; provider-sync is sole writer (v1.3 head note). |
| CJK token heuristic undercount? | Known issue; token extraction is out of scope here (see docs/architecture/OPEN-ISSUES.md). |

## 7. Verification Matrix
| # | Test | Maps to |
|---|------|---------|
| V1 | `tests/config/test_cost_calc.sh` (plain-LuaJIT unit tests) | FR-3.x, FR-4.2, FR-4.5 |
| V2 | `tests/config/test_model_registry.sh` single-writer guards | FR-1.2 |
| V3 | `tests/integration/test_cost_e2e.sh` | FR-4.1, FR-4.2 |

## 8. Implementation Status
| Item | Status | Evidence |
|------|--------|----------|
| FR-1.1-1.4 read-only module | Implemented | plugins/custom/cost_calc.lua (149 lines, no writer path) |
| FR-2.1-2.3 canonical keys | Implemented | cost_calc.lua:35-37, 60-107 |
| FR-3.1-3.5 cost math | Implemented | cost_calc.lua compute_cost; tests/config/test_cost_calc.sh |
| FR-3.6 historical recalculation | Implemented | res/scripts/recalc-costs.sh; tests/config/test_recalc_costs.sh |
| FR-4.1-4.5 failure behavior | Implemented | cost_calc.lua:136-147, 94-96 |
| Earlier writer path | Removed | absent from cost_calc.lua; removed per earlier v1.3 note |
