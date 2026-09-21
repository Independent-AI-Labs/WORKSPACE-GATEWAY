-- backfill-reasoning-tokens.sh: final posture check.
SELECT countIf(reasoning_tokens > 0), sum(reasoning_tokens)
FROM {{ DB }}.usage_log
FORMAT TabSeparated
