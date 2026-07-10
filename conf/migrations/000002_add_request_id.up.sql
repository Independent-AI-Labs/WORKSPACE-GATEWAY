-- 000002_add_request_id.up.sql
-- Add request_id String column to usage_log so usage rows can be joined
-- to request_log rows on the same correlation id (set by the APISIX
-- request-id plugin via the X-Request-Id header). Idempotent.

ALTER TABLE llm_gateway.usage_log
    ADD COLUMN IF NOT EXISTS request_id String DEFAULT '';