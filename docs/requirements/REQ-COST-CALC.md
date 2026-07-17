# REQ-COST-CALC: Cost Calculation Module

**Date:** 2026-07-17
**Status:** Active
**Type:** Requirements
**Specification:** [SPEC-COST-CALC](../specifications/SPEC-COST-CALC.md)

> Mandates cost calculation behavior for [`plugins/custom/cost_calc.lua`](../../plugins/custom/cost_calc.lua): a read-only pricing consumer exposing only `get_pricing`, `compute_cost`, `resolve_cost`; `provider-sync` (`provider_sync_pricing.lua`) is the single writer of `pricing:*` keys in the `gateway-cache` shared dict, keyed by canonical model id; unknown pricing yields cost 0 with `cost_source = unknown` and a logged warning  -  never a crash, never a guess. The legacy writer path (`warmup()`/`fetch_and_cache()`/`normalize_key()` from the legacy COST-CALC-LUA spec) is REMOVED and excluded.

---

**Cross-references:**
- [SPEC-COST-CALC](../specifications/SPEC-COST-CALC.md): companion specification
- [`plugins/custom/cost_calc.lua`](../../plugins/custom/cost_calc.lua): owns the module
- [`plugins/custom/provider_sync_pricing.lua`](../../plugins/custom/provider_sync_pricing.lua): sole `pricing:*` writer
- Legacy COST-CALC-LUA spec (head note v1.3 current; writer path sections removed, absorbed)
- [`tests/config/test_model_registry.sh`](../../tests/config/test_model_registry.sh): enforces the single-writer rule

---

## 1. Purpose & Scope

### 1.1 Purpose
Provide deterministic, auditable per-request USD cost for every usage row, preferring upstream-reported cost, else computing locally from a cached pricing table, and degrading safely when pricing is unknown.

### 1.2 Scope
**This document OWNS the requirements for:**
- The read-only consumer rule and single-writer rule for `pricing:*` keys
- Canonical pricing key derivation
- Cost math over input/output/cache/reasoning tokens
- Failure behavior on unknown pricing

**This document DOES NOT:**
- Define provider-sync catalog fetching (owned by provider-sync specs)
- Define token extraction (REQ-BILLING-TELEMETRY)
- Describe the removed writer path from the legacy COST-CALC-LUA spec

### 1.3 Terminology
| Term | Definition |
|------|------------|
| pricing:* key | JSON blob in shared dict `gateway-cache` under `pricing:<canonical-model-id>` with numeric `input`, `output`, optional `cache_read`, `reasoning` (per 1M tokens) |
| Canonical model id | Output of `model_registry.canonical()` from `conf/model-registry.yaml` |
| cost_source | `upstream` (provider-reported), `computed` (local math), `unknown` (no pricing) |

## 2. Functional Requirements

### FR-1: Read-Only Consumer
| ID | Requirement |
|----|-------------|
| FR-1.1 | `cost_calc` MUST be a pure Lua module, NOT a registered APISIX plugin: no schema, no priority, no phase bindings. |
| FR-1.2 | `cost_calc` MUST NOT write any `pricing:*` key. The ONLY writer MUST be `provider_sync_pricing.lua` (enforced by `tests/config/test_model_registry.sh`, which greps for `dict:set("pricing:"`). |
| FR-1.3 | `cost_calc` MUST NOT fetch models.dev or any remote pricing source itself. |
| FR-1.4 | The module MUST expose exactly the public functions `get_pricing(model_id)`, `compute_cost(tokens, price)`, `resolve_cost(sse_cost, tokens, model_id)` plus the `SOURCE_UPSTREAM`/`SOURCE_COMPUTED`/`SOURCE_UNKNOWN` constants. |

### FR-2: Canonical Pricing Keys
| ID | Requirement |
|----|-------------|
| FR-2.1 | All pricing lookups MUST be keyed by `model_registry.canonical(model_id)`; the module MUST contain no local key-normalization logic. |
| FR-2.2 | The shared dict MUST be `gateway-cache` with key prefix `pricing:`. |
| FR-2.3 | On a cache miss where `providers:ts` is absent (provider-sync never ran), the module MAY trigger `provider-sync.sync({})` once and re-read; if provider-sync has run and the key is absent, it MUST return miss without retry. |

### FR-3: Cost Math
| ID | Requirement |
|----|-------------|
| FR-3.1 | `compute_cost` MUST compute: `(pt - cached) * input / 1e6 + (ct - reasoning) * output / 1e6 + cached * cache_read / 1e6 + reasoning * reasoning_rate / 1e6`, with negative components clamped to 0. |
| FR-3.2 | `reasoning_rate` MUST default to `output` when the price has no `reasoning` field. |
| FR-3.3 | `cache_read` pricing MUST be supported; a missing `cache_read` rate MUST be treated as 0. |
| FR-3.4 | All token/rate values MUST be coerced with `tonumber(...) or 0`. |

### FR-4: Failure Behavior
| ID | Requirement |
|----|-------------|
| FR-4.1 | `resolve_cost` MUST return `(sse_cost, "upstream")` when the upstream SSE/JSON payload carries a positive cost. |
| FR-4.2 | When no upstream cost and no pricing, `resolve_cost` MUST return `(0, "unknown")`  -  cost MUST NOT be fabricated. |
| FR-4.3 | When pricing is unavailable and provider-sync cannot help, the module MUST log a warning (`core.log.warn`) naming the canonical key. |
| FR-4.4 | A missing price table or a price table without numeric `input` MUST be treated as a miss. |
| FR-4.5 | `compute_cost`/`resolve_cost` (upstream + unknown branches) MUST be loadable in plain LuaJIT without the nginx runtime (deferred requires), so unit tests run with zero dependency injection. |

## 3. Non-Functional Requirements
| ID | Requirement |
|----|-------------|
| NFR-1.1 | The pricing lookup MUST be an in-memory shared-dict read on the hot path. |
| NFR-1.2 | Cross-provider "cheapest-wins" merging MUST NOT occur; each model's price comes from its catalogued provider only (fixes the historical collision/overcharge class of bug). |

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
| Legacy writer path (`warmup`/`fetch_and_cache`/`normalize_key`)? | Removed; provider-sync is sole writer (v1.3 head note). |
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
| FR-3.1-3.4 cost math | Implemented | cost_calc.lua:109-134 |
| FR-4.1-4.5 failure behavior | Implemented | cost_calc.lua:136-147, 94-96 |
| Legacy writer path | Removed | absent from cost_calc.lua; removed per legacy v1.3 note |
