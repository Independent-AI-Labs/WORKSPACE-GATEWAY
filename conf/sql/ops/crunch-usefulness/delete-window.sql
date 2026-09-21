-- crunch-usefulness.sh: idempotent per-block delete before re-insert.
ALTER TABLE {{ DB }}.request_signals
DELETE WHERE timestamp >= '{{ BLOCK_START }}' AND timestamp < '{{ BLOCK_END }}'
SETTINGS mutations_sync = 2
