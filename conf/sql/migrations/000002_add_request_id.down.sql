-- 000002_add_request_id.down.sql
-- Reverse of 000002: drop the request_id column. Joins to request_log will
-- no longer be possible on rows written before the next `up` run.

ALTER TABLE llm_gateway.usage_log
    DROP COLUMN IF EXISTS request_id;