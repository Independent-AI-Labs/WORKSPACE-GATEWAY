-- backfill-migrated-ttft.sh: rewrite content TTFT for migrated rows from the
-- Join-engine lookup. Only reasoning-first messages change (their old stamp was
-- the first visible answer text). Idempotent: the difference guard leaves rows
-- already carrying the corrected value untouched.
ALTER TABLE {{ DB }}.usage_log
UPDATE ttft_content_ms = joinGet('{{ DB }}.migrated_ttft_backfill', 'ttft', event_id)
WHERE event_id IN (SELECT event_id FROM {{ DB }}.migrated_ttft_backfill)
  AND ttft_content_ms != joinGet('{{ DB }}.migrated_ttft_backfill', 'ttft', event_id)
SETTINGS mutations_sync = 1