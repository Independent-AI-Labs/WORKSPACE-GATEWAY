-- backfill-migrated-ttft.sh: drop the transient lookup table.
DROP TABLE IF EXISTS {{ DB }}.migrated_ttft_backfill