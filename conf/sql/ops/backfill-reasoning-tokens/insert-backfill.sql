-- backfill-reasoning-tokens.sh: batched insert of computed values.
INSERT INTO {{ DB }}.reasoning_backfill
(event_id, model, key_id, ts, reasoning_tokens, reasoning_chars)
VALUES {{ BUF }}
