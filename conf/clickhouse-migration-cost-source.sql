-- conf/clickhouse-migration-cost-source.sql
-- Migration script: adds cost_source column to usage_log.
-- Idempotent - safe to run multiple times (uses ADD COLUMN IF NOT EXISTS).
-- Intended for existing deployments where clickhouse-init.sql was run
-- before the cost_source column was added.
--
-- Usage:
--   curl 'http://localhost:8123/?query=SOURCE+conf/clickhouse-migration-cost-source.sql'
--   or alternatively:
--   clickhouse-client --queries-file conf/clickhouse-migration-cost-source.sql

ALTER TABLE llm_gateway.usage_log
    ADD COLUMN IF NOT EXISTS cost_source
    Enum8('upstream' = 0, 'computed' = 1, 'unknown' = 2)
    DEFAULT 2
    AFTER cost;
