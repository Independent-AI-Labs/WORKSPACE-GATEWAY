-- backfill-reasoning-tokens.sh: staging table for computed token counts.
CREATE TABLE IF NOT EXISTS {{ DB }}.reasoning_backfill (
    event_id         String,
    model            String,
    key_id           String,
    ts               DateTime64(3),
    reasoning_tokens UInt32,
    reasoning_chars  UInt32
) ENGINE = MergeTree()
ORDER BY (event_id)
