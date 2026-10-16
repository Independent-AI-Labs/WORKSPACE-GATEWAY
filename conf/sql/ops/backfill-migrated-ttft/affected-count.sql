-- backfill-migrated-ttft.sh: migrated rows whose stored TTFT differs from the
-- corrected value (read-only).
SELECT count()
FROM {{ DB }}.usage_log AS u
WHERE u.event_id IN (SELECT event_id FROM {{ DB }}.migrated_ttft_backfill AS b)
  AND u.ttft_content_ms != joinGet('{{ DB }}.migrated_ttft_backfill', 'ttft', u.event_id)
FORMAT TabSeparated