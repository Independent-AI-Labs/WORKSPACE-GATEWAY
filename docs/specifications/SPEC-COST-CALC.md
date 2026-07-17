# SPEC-COST-CALC: Cost Calculation Module Implementation

**Date:** 2026-07-17
**Status:** Active
**Type:** Specification
**Requirements:** [REQ-COST-CALC](../requirements/REQ-COST-CALC.md)

> Describes [`plugins/custom/cost_calc.lua`](../../plugins/custom/cost_calc.lua) as it exists today: a pure Lua module (not an APISIX plugin) exposing `get_pricing` / `compute_cost` / `resolve_cost`, reading `pricing:<canonical-id>` JSON from the `gateway-cache` shared dict. Key invariant: provider-sync is the sole pricing writer  -  enforced by `tests/config/test_model_registry.sh`.

---

**Cross-references:**
- [REQ-COST-CALC](../requirements/REQ-COST-CALC.md): requirements
- [`plugins/custom/cost_calc.lua`](../../plugins/custom/cost_calc.lua): the module (149 lines)
- [`plugins/custom/provider_sync_pricing.lua`](../../plugins/custom/provider_sync_pricing.lua): sole `pricing:*` writer
- [`plugins/custom/model_registry.lua`](../../plugins/custom/model_registry.lua): canonical model ids (generated)
- [`plugins/custom/sse-usage.lua`](../../plugins/custom/sse-usage.lua): sole in-tree caller
- Legacy COST-CALC-LUA spec (v1.3 head note current; writer path removed, absorbed)

---

## 1. Overview

`cost_calc` converts token counts plus a pricing record into a USD cost, or passes through an upstream-reported cost. It never writes pricing data and never calls models.dev. It is required by `sse-usage.lua` in the log phase and by unit tests running in plain LuaJIT.

## 2. Architectural Principles

### 2.1 Single-writer invariant
Only `provider_sync_pricing.lua` executes `dict:set("pricing:" ...)` against the `gateway-cache` shared dict. `tests/config/test_model_registry.sh` (section 3, "single-writer guards") greps all of `plugins/custom/` and asserts the writer list equals exactly `provider_sync_pricing.lua`.

### 2.2 Canonical keying
Lookup key = `model_registry.canonical(model_id)`, sourced from `conf/model-registry.yaml` codegen. No normalization logic lives in cost_calc.

### 2.3 Deferred requires
`apisix.core`, `cjson.safe`, and the `ngx` global are required inside functions, not at module top level, so `compute_cost` and the upstream/unknown branches of `resolve_cost` run under plain LuaJIT with zero dependency injection.

## 3. System Diagram

```
provider-sync (catalog+pricing) --dict:set--> gateway-cache["pricing:<canon>"]
                                                      |
sse-usage.log --cost_calc.resolve_cost(sse_cost,------+
              tokens, model_id)
                 |-> sse_cost > 0        => (cost, "upstream")
                 |-> get_pricing hit     => (compute_cost, "computed")
                 |-> miss (+warn)        => (0, "unknown")
```

## 4. Public API

| Function | Signature | Returns |
|----------|-----------|---------|
| `get_pricing` | `(model_id)` | `(price_table, "fresh")` or `(nil, "miss")` |
| `compute_cost` | `(tokens, price)` | number (USD) |
| `resolve_cost` | `(sse_cost, tokens, model_id)` | `(cost, source)` where source ∈ `M.SOURCE_UPSTREAM` / `M.SOURCE_COMPUTED` / `M.SOURCE_UNKNOWN` |

Constants: `SHARED_DICT = "gateway-cache"`, `PRICING_KEY_PREFIX = "pricing:"`, `PROVIDER_SYNC_TS_KEY = "providers:ts"`.

## 5. Pricing Dict Lookup (`get_pricing`)

1. No `ngx.shared` (plain LuaJIT) → `(nil, "miss")`.
2. `key = model_registry.canonical(model_id)`; empty → miss.
3. Read `gateway-cache["pricing:" .. key]`. Hit → `cjson.safe` decode; require a table with numeric `input`, else miss → `(price, "fresh")`.
4. Miss: if `providers:ts` exists (provider-sync already ran), the model is not catalogued → miss.
5. Miss and provider-sync never ran: `pcall(provider_sync.sync, {})` once, re-read; still absent → miss.
6. Unrecoverable miss with provider-sync unavailable → `core.log.warn("cost_calc: no pricing for '<key>' ...")`.

## 6. Cost Math (`compute_cost`)

```
input_uncached        = max(pt - cached, 0)
output_non_reasoning  = max(ct - reasoning, 0)
reasoning_rate        = price.reasoning or price.output
cost = input_uncached       * price.input      / 1e6
     + output_non_reasoning * price.output     / 1e6
     + cached               * price.cache_read / 1e6
     + reasoning            * reasoning_rate   / 1e6
```

All fields coerced via `tonumber(...) or 0`; missing `cache_read` = 0; nil `tokens`/`price` → 0.

## 7. Resolution Order (`resolve_cost`)

1. `sse_cost` numeric and > 0 → `(sse_cost, "upstream")` (provider-reported wins).
2. Else `get_pricing(model_id)`; miss → `(0, "unknown")`.
3. Else `(compute_cost(tokens, price), "computed")`.

## 8. Integration Points

- **Caller:** `sse-usage.lua:166-170`  -  passes `{ pt, ct, cached, reasoning }` from `sse_usage_lib.extract_tokens` and the request model; result lands in `usage_log.cost` / `cost_source` and the `quota_counters` cost increment (`math.ceil(cost * 100)`).
- **Warm cache:** `sse-usage.plugin.init` triggers `provider-sync.sync({})` at startup so the first request rarely hits the cold-miss path.
- **Historical alias dedupe:** `res/scripts/dedupe-model-history.sh` merges alias rows (supersedes `backfill-provider-costs.sh`).

## 9. Edge Cases & Decisions

- The legacy writer path (`warmup()`, `fetch_and_cache()`, `normalize_key()` from the legacy COST-CALC-LUA spec) is REMOVED; the module contains no writer code.
- First-writer-wins, sorted-provider semantics in provider-sync eliminate the cross-provider cheapest-wins collision (historical 14% overcharge).
- On unknown pricing, cost is 0 and `cost_source = unknown`; billing rows remain auditable rather than dropped.

## 10. File Map

| File | Purpose | Key Changes |
|------|---------|-------------|
| [`plugins/custom/cost_calc.lua`](../../plugins/custom/cost_calc.lua) | Read-only cost module |  -  |
| [`plugins/custom/provider_sync_pricing.lua`](../../plugins/custom/provider_sync_pricing.lua) | Sole `pricing:*` writer |  -  |
| [`plugins/custom/model_registry.lua`](../../plugins/custom/model_registry.lua) | Canonical ids (generated) |  -  |
| [`conf/model-registry.yaml`](../../conf/model-registry.yaml) | Model identity source of truth |  -  |
| [`tests/config/test_cost_calc.sh`](../../tests/config/test_cost_calc.sh) | Plain-LuaJIT unit tests |  -  |
| [`tests/config/test_model_registry.sh`](../../tests/config/test_model_registry.sh) | Single-writer + codegen-drift guards |  -  |

## 11. Implementation Status

| Component | Status | Evidence |
|-----------|--------|----------|
| get_pricing / compute_cost / resolve_cost | Implemented | cost_calc.lua:60-147 |
| Single-writer guard | Implemented | tests/config/test_model_registry.sh:113-116 |
| Canonical keying | Implemented | cost_calc.lua:66 |
| LuaJIT-testable deferred requires | Implemented | cost_calc.lua:16-31, 43-50 |
| Legacy writer path | Removed | absent from cost_calc.lua |
