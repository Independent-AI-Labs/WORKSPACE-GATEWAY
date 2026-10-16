-- backfill-migrated-ttft.sh: post-apply posture. `remaining` MUST be 0;
-- `matched` counts mapped rows now carrying the corrected value.
SELECT
    (SELECT count()
     FROM {{ DB }}.usage_log AS u
     WHERE u.event_id IN (SELECT event_id FROM {{ DB }}.migrated_ttft_backfill AS b)
       AND u.ttft_content_ms != joinGet('{{ DB }}.migrated_ttft_backfill', 'ttft', u.event_id)) AS remaining,
    (SELECT count()
     FROM {{ DB }}.usage_log AS u
     WHERE u.event_id IN (SELECT event_id FROM {{ DB }}.migrated_ttft_backfill AS b)
       AND u.ttft_content_ms = joinGet('{{ DB }}.migrated_ttft_backfill', 'ttft', u.event_id)) AS matched
FORMAT TabSeparatedWithNames