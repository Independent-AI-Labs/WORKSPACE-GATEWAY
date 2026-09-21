-- 000013_reported_cost_and_source_enum.down.sql
-- Restore the prior `upstream`/`computed` domain. Forward-only in
-- production, this exists for local reversibility.
--   1. collapse provenance to 'unknown' so the enum can be reinterpreted
--   2. swap the enum back
--   3. recover 'upstream' for rows that carried reported_cost
--   4. drop the column.
ALTER TABLE llm_gateway.usage_log
    UPDATE cost_source = 'unknown' WHERE cost_source != 'unknown'
    SETTINGS mutations_sync = 1;

ALTER TABLE llm_gateway.usage_log
    MODIFY COLUMN cost_source
    Enum8('upstream' = 0, 'computed' = 1, 'unknown' = 2) DEFAULT 2;

ALTER TABLE llm_gateway.usage_log
    UPDATE cost_source = 'upstream' WHERE reported_cost > 0
    SETTINGS mutations_sync = 1;

ALTER TABLE llm_gateway.usage_log
    DROP COLUMN IF EXISTS reported_cost;
