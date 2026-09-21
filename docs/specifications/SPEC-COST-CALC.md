# SPEC-COST-CALC: Cost Calculation Module Implementation

**Date:** 2026-07-17
**Status:** Active
**Type:** Specification
**Requirements:** [REQ-COST-CALC](../requirements/REQ-COST-CALC.md)

> Describes [`plugins/custom/cost_calc.lua`](../../plugins/custom/cost_calc.lua) as it exists today: a pure Lua module (not an APISIX plugin) exposing `get_pricing` / `compute_cost` / `resolve_cost`, reading `pricing:<provider-id>:<canonical-id>` JSON from the `gateway-cache` shared dict. Key invariant: provider-sync is the sole pricing writer - enforced by repository guards.

---

**Cross-references:**
- [REQ-COST-CALC](../requirements/REQ-COST-CALC.md): requirements
- [`plugins/custom/cost_calc.lua`](../../plugins/custom/cost_calc.lua): the module (149 lines)
- [`plugins/custom/provider_sync_pricing.lua`](../../plugins/custom/provider_sync_pricing.lua): sole `pricing:*` writer
- [`plugins/custom/model_registry.lua`](../../plugins/custom/model_registry.lua): canonical model ids (generated)
- [`plugins/custom/sse-usage.lua`](../../plugins/custom/sse-usage.lua): sole in-tree caller
- Earlier COST-CALC-LUA spec (v1.3 head note current; writer path removed, absorbed)

---

## 1. Overview

`cost_calc` converts token counts plus a pricing record into a USD cost. It never writes pricing data and never calls models.dev. It is required by `sse-usage.lua` in the log phase and by unit tests running in plain LuaJIT. Billed cost is resolved in two steps only: the provider's `pricing.overrides` (manual declaration), else models.dev. Upstream-reported cost is captured separately by `sse-usage` as reported-cost metadata and does not pass through `resolve_cost`.

## 2. Architectural Principles

### 2.1 Single-writer invariant
Only `provider_sync_pricing.lua` executes `dict:set("pricing:" ...)` against the `gateway-cache` shared dict. `tests/config/test_model_registry.sh` (section 3, "single-writer guards") greps all of `plugins/custom/` and asserts the writer list equals exactly `provider_sync_pricing.lua`.

### 2.2 Provider-scoped canonical keying
Lookup key = `provider_id .. ":" .. model_registry.canonical(model_id)`, sourced from `conf/model-registry.yaml` codegen. No normalization logic lives in cost_calc.

### 2.3 Deferred requires
`apisix.core`, `cjson.safe`, and the `ngx` global are required inside functions, not at module top level, so `compute_cost` and the priced/unknown branches of `resolve_cost` run under plain LuaJIT with zero dependency injection.

### 2.4 Explicit provider identity
`cost_calc` is the single source of the route→provider map (`ROUTE_PROVIDERS`)
and the prior gateway-alias map (`PROVIDER_ALIASES`); `sse-usage.lua` and the
offline recalc both resolve providers through `resolve_provider`. Resolution is
explicit only: a known alias wins, a non-empty id passes through verbatim, an
empty id takes the route recovered from `event_id`, and an unmapped
route stays empty. No other provider is consulted: an unresolved row is
left untouched rather than misattributed. opencode's own direct providers
(`openai`, `opencode`, `opencode-go`, `zai-coding-plan`, `amazon-bedrock`,
`workspace-gateway`) are deliberately not remapped.

## 3. System Diagram

```
 provider-sync (catalog+pricing) --dict:set--> gateway-cache["pricing:<provider>:<canon>"]
                                                       |
 sse-usage.log --cost_calc.resolve_cost(--------------+
               tokens, model_id, provider_id)
                  |-> get_pricing hit     => (compute_cost, "provider_override" | "models_dev")
                  |-> miss (+warn)        => (0, "unknown")

 sse-usage.log --reported_cost (upstream payload)----> usage_log.reported_cost (metadata only)
```

## 4. Public API

| Function | Signature | Returns |
|----------|-----------|---------|
| `get_pricing` | `(model_id, provider_id)` | `(price_table, "fresh")` or `(nil, "miss")` |
| `compute_cost` | `(tokens, price)` | number (USD) |
| `resolve_cost` | `(tokens, model_id, provider_id)` | `(cost, source)` where source ∈ `M.SOURCE_PROVIDER_OVERRIDE` / `M.SOURCE_MODELS_DEV` / `M.SOURCE_UNKNOWN` |
| `route_of` | `(event_id)` | route id (`event_id` minus its trailing `_<epoch>`) |
| `resolve_provider` | `(provider_id, event_id)` | resolved gateway provider id, or `""` (no other provider) |

Constants: `SHARED_DICT = "gateway-cache"`, `PRICING_KEY_PREFIX = "pricing:"`, `ROUTE_PROVIDERS` (route id → gateway provider id), `PROVIDER_ALIASES` (prior gateway provider id → canonical gateway provider id).

## 5. Pricing Dict Lookup (`get_pricing`)

1. No `ngx.shared` (plain LuaJIT) → `(nil, "miss")`.
2. `key = provider_id .. ":" .. model_registry.canonical(model_id)`; missing provider or empty canonical id → miss.
3. Read `gateway-cache["pricing:" .. key]`. Hit → `cjson.safe` decode; require a table with numeric `input`, else miss → `(price, "fresh")`.
4. Miss → `(nil, "miss")`. The module is read-only: it never fetches and never triggers a sync. provider-sync warms the cache in `plugin.init()` and via `POST /gateway/providers/sync`.

## 6. Cost Math (`compute_cost`)

```
input_uncached        = max(pt - cached - cache_write, 0)
output_non_reasoning  = max(ct - reasoning, 0)
if ct - reasoning < 0 then output_non_reasoning = ct end   -- reasoning is a separate dimension
reasoning_rate        = price.reasoning if > 0 else price.output
cache_read_rate       = price.cache_read  if > 0 else price.input   -- never bill cache reads free
cache_write_rate      = price.cache_write if > 0 else price.input
cost = input_uncached       * price.input       / 1e6
     + output_non_reasoning * price.output      / 1e6
     + cached               * cache_read_rate   / 1e6
     + cache_write          * cache_write_rate  / 1e6
     + reasoning            * reasoning_rate    / 1e6
```

All fields coerced via `tonumber(...) or 0`; nil `tokens`/`price` → 0. `cache_write`
is the write-to-cache prompt volume (Anthropic `cache_creation_input_tokens`);
`cached` is the read-from-cache volume. Both are subtracted from `pt` before the
uncached term so cache tokens are never double-billed. A provider that does not
publish a cache rate falls back to the `input` rate rather than billing the
tokens free. The `ct - reasoning < 0` guard covers providers whose `reasoning`
count is a separate stream rather than a subset of `completion_tokens`.

### 6.1 Historical Recalculation (`res/scripts/recalc-costs.sh`)

A persistent, idempotent, non-destructive repair tool revalues rows written
before the formula above (or before a provider catalog fix). It shares exactly
one formula with the request path by invoking `cost_calc.compute_cost` through
`res/scripts/cost/recalc.lua`.

- **Dry run by default.** Nothing is written without `--apply`.
- **Small batch by default** (`--limit 100`); `--all` additionally requires
  `--confirm-all`, so a full-table pass is always an explicit decision.
- **Provider-scoped rates** are read from the live catalog
  (`/gateway/providers/:id`), keyed `provider_id:canonical`, never from a
  provider-agnostic map.
- **Provider resolution + backfill.** Each row's gateway provider is resolved
  through `cost_calc.resolve_provider` (section 2.4): prior aliases are
  canonicalized and empty ids are recovered from the route in `event_id`. A row
  whose resolved provider differs is corrected even when its cost does not
  change (provider_id-only backfill). The `--source` selector accepts the billed
  provenance values `unknown,models_dev,provider_override`.
- **Billed cost is always recomputed** from the provider's `pricing.overrides` or its declared models.dev namespace. There is no upstream-cost exemption: the previous `cost_source = 'upstream'` scope is retired. The reported-cost metadata column is never mutated.
- **Default scope** is every row whose billed provenance is not already correct, i.e. `cost_source IN ('provider_override','models_dev','unknown')`.
- **Mandatory verified backup** (`BACKUP DATABASE ... TO Disk('backups', ...)`)
  before the first mutation; the pass aborts unless the backup status is
  `BACKUP_CREATED` (opt out only with an explicit `--no-backup`).
- **Audit before mutate**: every old→new pair is appended to
  `llm_gateway.cost_recalc_audit` (`provider_id`, `new_provider_id`, old/new
  cost and source; no row is ever deleted).
- **Bulk, targeted and idempotent**: ClickHouse re-encodes whole parts per
  mutation, so corrections are collapsed into `ALTER TABLE ... UPDATE` groups,
  not issued per row: one provider_id UPDATE per resolved mapping (alias, or
  route pattern for empty ids) and one cost UPDATE per distinct
  `(provider, rate)` tuple. A full repair is tens of statements. Each cost
  UPDATE shares `cost_calc.compute_cost`'s arithmetic, is gated on
  `cost_source IN (...)` and `abs(cost - expr) > epsilon`, and rewrites
  cost/source only where the value differs; provider backfill is likewise gated
  on the previous `provider_id`. Re-running converges to a no-op.
- Lua emits corrections separated by the ASCII unit separator (`\31`) so an
  empty `request_id` (migrated rows) is not collapsed by the shell's tab `IFS`;
  each row also carries its canonical model and the five rate coefficients so
  the shell can group without a second rate source.

## 7. Resolution Order (`resolve_cost`)

1. `get_pricing(model_id, provider_id)`; miss → `(0, "unknown")`.
2. Hit → `(compute_cost(tokens, price), price.pricing_source)` when `pricing_source` is exactly `provider_override` or `models_dev`. Any other provenance is a writer contract violation: log an error and return `(0, "unknown")` rather than mislabel the row.

The upstream-reported cost never participates: `sse-usage` extracts it into `usage_log.reported_cost` independently of the billed `cost`/`cost_source`.

## 8. Integration Points

- **Caller:** `sse-usage.lua` passes `{ pt, ct, cached, cache_write, reasoning }`, the request model, and route-derived provider id; the resolved billed cost lands in `usage_log.cost` / `cost_source` and the `quota_counters` cost increment (`math.ceil(cost * 100)`). The upstream-reported cost is written to `usage_log.reported_cost` separately.
- **Warm cache:** `sse-usage.plugin.init` triggers `provider-sync.sync({})` at startup so the first request rarely hits the cold-miss path.
- **Historical alias dedupe:** `res/scripts/dedupe-model-history.sh` merges alias rows only (supersedes `backfill-provider-costs.sh`); it no longer rewrites cost.
- **Historical recalculation:** `res/scripts/recalc-costs.sh` revalues existing rows (section 6.1); cost repair is owned by this tool, not by dedupe.

## 9. Edge Cases & Decisions

- The earlier writer path (`warmup()`, `fetch_and_cache()`, `normalize_key()` from the earlier COST-CALC-LUA spec) is REMOVED; the module contains no writer code.
- Provider-scoped records eliminate cross-provider key collisions; sync publishes an immutable pricing snapshot and active snapshot generation. Billed cost is derived from the provider's own override or its declared models.dev namespace only - never from a cross-provider scan or a metadata/discovery join.
- On unknown pricing, cost is 0 and `cost_source = unknown`; billing rows remain auditable rather than dropped. Reported upstream cost remains available as metadata.

## 10. File Map

| File | Purpose | Key Changes |
|------|---------|-------------|
| [`plugins/custom/cost_calc.lua`](../../plugins/custom/cost_calc.lua) | Read-only cost module |  -  |
| [`plugins/custom/provider_sync_pricing.lua`](../../plugins/custom/provider_sync_pricing.lua) | Sole `pricing:*` writer |  -  |
| [`plugins/custom/model_registry.lua`](../../plugins/custom/model_registry.lua) | Canonical ids (generated) |  -  |
| [`conf/model-registry.yaml`](../../conf/model-registry.yaml) | Model identity source of truth |  -  |
| [`tests/config/test_cost_calc.sh`](../../tests/config/test_cost_calc.sh) | Plain-LuaJIT unit tests |  -  |
| [`tests/config/test_model_registry.sh`](../../tests/config/test_model_registry.sh) | Single-writer + codegen-drift guards |  -  |
| [`res/scripts/cost/recalc.lua`](../../res/scripts/cost/recalc.lua) | Recalculation core (shared formula) |  -  |
| [`res/scripts/recalc-costs.sh`](../../res/scripts/recalc-costs.sh) | Idempotent, backup-gated recalc driver |  -  |
| [`tests/config/test_recalc_costs.sh`](../../tests/config/test_recalc_costs.sh) | Recalc safety-contract guard |  -  |
| [`tests/lua/test_cost_recalc.lua`](../../tests/lua/test_cost_recalc.lua) | recalc.lua unit tests |  -  |

## 11. Implementation Status

| Component | Status | Evidence |
|-----------|--------|----------|
| get_pricing / compute_cost / resolve_cost | Implemented | cost_calc.lua:60-147 |
| Single-writer guard | Implemented | tests/config/test_model_registry.sh:113-116 |
| Canonical keying | Implemented | cost_calc.lua:66 |
| LuaJIT-testable deferred requires | Implemented | cost_calc.lua:16-31, 43-50 |
| cache_write billing + missing-cache-rate handling | Implemented | cost_calc.lua compute_cost |
| Route/alias provider resolution + provider_id backfill | Implemented | cost_calc.lua `ROUTE_PROVIDERS`/`PROVIDER_ALIASES`/`resolve_provider`; recalc.lua `M.resolve` |
| Historical recalculation tool | Implemented | res/scripts/recalc-costs.sh |
| Earlier writer path | Removed | absent from cost_calc.lua |
