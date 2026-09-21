-- Reset migrated rows by event_id prefix.
ALTER TABLE llm_gateway.{{ TABLE }}
DELETE WHERE event_id LIKE '{{ PREFIX }}%'
SETTINGS mutations_sync = 2
