-- 000016_add_category_costs.down.sql
-- Reverse of 000016: drop the per-token-category cost columns. Values are
-- recomputable from token counts plus the provider-scoped rates, but are
-- discarded here. Re-running `up` re-adds them at 0 and the next
-- recalc-costs.sh pass restores the split.

ALTER TABLE llm_gateway.usage_log
    DROP COLUMN IF EXISTS cost_reasoning;

ALTER TABLE llm_gateway.usage_log
    DROP COLUMN IF EXISTS cost_output;

ALTER TABLE llm_gateway.usage_log
    DROP COLUMN IF EXISTS cost_cache_write;

ALTER TABLE llm_gateway.usage_log
    DROP COLUMN IF EXISTS cost_cached;

ALTER TABLE llm_gateway.usage_log
    DROP COLUMN IF EXISTS cost_input_uncached;
