-- backfill-reasoning-tokens.sh: drop the staging table.
DROP TABLE IF EXISTS {{ DB }}.reasoning_backfill
