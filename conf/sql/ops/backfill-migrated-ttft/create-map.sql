-- backfill-migrated-ttft.sh: transient Join-engine lookup table mapping
-- migrated usage_log event_ids (ocm_<message_id>) to the corrected content
-- TTFT. joinGet lets one mutation rewrite every row without a staging merge.
CREATE TABLE IF NOT EXISTS {{ DB }}.migrated_ttft_backfill (
    event_id String,
    ttft     UInt32
) ENGINE = Join(ANY, LEFT, event_id)