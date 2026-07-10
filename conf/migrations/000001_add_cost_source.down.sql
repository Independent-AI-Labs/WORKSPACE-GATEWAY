-- 000001_add_cost_source.down.sql
-- Reverse of 000001: drop the cost_source column. Any historical values
-- are discarded; re-running `up` re-adds the column with default 'gateway'.

ALTER TABLE llm_gateway.usage_log
    DROP COLUMN IF EXISTS cost_source;