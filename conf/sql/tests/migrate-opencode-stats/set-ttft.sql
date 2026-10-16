-- Seed a content-TTFT value on one row (backfill-migrated-ttft test setup).
ALTER TABLE llm_gateway.usage_log
UPDATE ttft_content_ms = {{ EXPR }}
WHERE event_id = '{{ EID }}'
SETTINGS mutations_sync = 1