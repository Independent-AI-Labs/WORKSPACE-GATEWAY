-- 000017 down: drop the RP service-log table. RP log history is discarded;
-- re-running the up migration recreates an empty table.

DROP TABLE IF EXISTS llm_gateway.service_log;