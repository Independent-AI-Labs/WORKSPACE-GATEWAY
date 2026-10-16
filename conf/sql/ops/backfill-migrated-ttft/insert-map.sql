-- backfill-migrated-ttft.sh: batched insert of corrected values.
INSERT INTO {{ DB }}.migrated_ttft_backfill (event_id, ttft) VALUES {{ BUF }}