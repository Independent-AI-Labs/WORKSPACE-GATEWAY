-- Remove seeded request_bodies rows in the window (cleanup replay).
ALTER TABLE llm_gateway.request_bodies
DELETE WHERE request_id LIKE '{{ PREFIX }}%'
  AND timestamp >= '{{ WT0 }}' AND timestamp < '{{ WT1 }}'
SETTINGS mutations_sync = 2
