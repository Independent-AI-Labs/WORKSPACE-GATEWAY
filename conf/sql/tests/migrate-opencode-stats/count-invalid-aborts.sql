-- Migrated abort values must be only 0/1/2.
SELECT countIf(aborted NOT IN (0, 1, 2)) FROM llm_gateway.usage_log WHERE event_id LIKE '{{ PREFIX }}%'
