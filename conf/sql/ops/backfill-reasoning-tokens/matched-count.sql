-- backfill-reasoning-tokens.sh: usage_log rows matched by the staging table.
SELECT count()
FROM {{ DB }}.usage_log AS u
WHERE u.reasoning_tokens = 0
  AND u.event_id IN (SELECT b.event_id FROM {{ DB }}.reasoning_backfill AS b)
FORMAT TabSeparated
