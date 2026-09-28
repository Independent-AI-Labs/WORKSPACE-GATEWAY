-- fix-model-attribution.sh: spot-check, in the request_log shadow before
-- the swap, the aliases known to have drifted plus anything whose raw still
-- fails the model-id shape guard (a re-run target).
SELECT model_raw, model, count() AS n
FROM {{ DB }}.request_log_backfill
WHERE (model_raw LIKE 'T:%' OR model_raw LIKE '%qwen3-coder-30b%')
   OR (model_raw != '' AND match(model_raw, '^[A-Za-z0-9._/-]+$') = 0)
GROUP BY model_raw, model
ORDER BY n DESC
LIMIT 25
FORMAT PrettyCompact
