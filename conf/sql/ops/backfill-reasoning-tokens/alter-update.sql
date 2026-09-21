-- backfill-reasoning-tokens.sh: apply one computed token count.
ALTER TABLE {{ DB }}.usage_log
UPDATE reasoning_tokens = {{ RT }}
WHERE event_id = {{ EFID }} AND reasoning_tokens = 0
SETTINGS mutations_sync = 1
