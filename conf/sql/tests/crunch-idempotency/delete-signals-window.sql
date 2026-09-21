-- Clear request_signals for a window before seeding.
ALTER TABLE llm_gateway.request_signals
DELETE WHERE timestamp >= '{{ WT0 }}' AND timestamp < '{{ WT1 }}'
SETTINGS mutations_sync = 2
