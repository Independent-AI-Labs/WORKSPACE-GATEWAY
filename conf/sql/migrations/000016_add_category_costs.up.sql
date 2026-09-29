-- 000016_add_category_costs.up.sql
-- Persist the per-token-category cost split so the dashboards can show the
-- exact spend of each token dimension instead of only the row total.
--
-- llm_gateway.usage_log keeps a single billed `cost`. The split cannot be
-- reconstructed later: the per-1M rates live in the nginx pricing dict, so
-- five component columns are written at ingest (cost_calc.cost_breakdown)
-- and backfilled by res/scripts/recalc-costs.sh for historical rows.
--
-- Mapping to the dashboard's token categories:
--   cost_input_uncached : max(prompt - cached - cache_write, 0) * input
--   cost_cached         : cached * cache_read
--   cost_cache_write    : cache_write * cache_write
--   cost_output         : output_non_reasoning * output
--   cost_reasoning      : reasoning * reasoning
-- The four displayed tiles fold cost_cache_write into Input (its token
-- bucket prompt-cached already includes cache-write tokens), so the four
-- category costs sum exactly to the billed cost.

ALTER TABLE llm_gateway.usage_log
    ADD COLUMN IF NOT EXISTS cost_input_uncached Float64 DEFAULT 0 AFTER reported_cost;

ALTER TABLE llm_gateway.usage_log
    ADD COLUMN IF NOT EXISTS cost_cached         Float64 DEFAULT 0 AFTER cost_input_uncached;

ALTER TABLE llm_gateway.usage_log
    ADD COLUMN IF NOT EXISTS cost_cache_write    Float64 DEFAULT 0 AFTER cost_cached;

ALTER TABLE llm_gateway.usage_log
    ADD COLUMN IF NOT EXISTS cost_output         Float64 DEFAULT 0 AFTER cost_cache_write;

ALTER TABLE llm_gateway.usage_log
    ADD COLUMN IF NOT EXISTS cost_reasoning      Float64 DEFAULT 0 AFTER cost_output;
