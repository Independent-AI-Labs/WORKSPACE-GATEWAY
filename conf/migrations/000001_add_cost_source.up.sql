-- 000001_add_cost_source.up.sql
-- Add cost_source Enum8 column to usage_log so per-row accounting knows
-- whether tokens were billed upstream (provider) or computed locally
-- (gateway / unknown). Idempotent: IF NOT EXISTS allows re-runs on
-- already-migrated databases (golang-migrate dirty-state recovery,
-- manual re-apply, etc.). Matches the Enum8 domain declared in
-- conf/clickhouse-init.sql line 169.

ALTER TABLE llm_gateway.usage_log
    ADD COLUMN IF NOT EXISTS cost_source
    Enum8('upstream' = 0, 'computed' = 1, 'unknown' = 2) DEFAULT 2;