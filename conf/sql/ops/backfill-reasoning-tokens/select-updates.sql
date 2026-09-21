-- backfill-reasoning-tokens.sh: rows to update in usage_log.
SELECT b.event_id, b.reasoning_tokens
FROM {{ DB }}.reasoning_backfill AS b
WHERE b.event_id IN (
    SELECT u.event_id FROM {{ DB }}.usage_log AS u WHERE u.reasoning_tokens = 0
)
FORMAT TabSeparated
