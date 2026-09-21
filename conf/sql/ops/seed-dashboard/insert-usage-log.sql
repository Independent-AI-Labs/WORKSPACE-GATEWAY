-- seed-clickhouse-dashboard-data.sh: matching usage_log rows for model
-- filter + ASOF JOIN panels.
INSERT INTO {{ DB }}.usage_log (
    event_id, request_id, model, key_id,
    prompt_tokens, completion_tokens, total_tokens, cost, timestamp
)
SELECT
    concat('{{ SEED_EID_PREFIX }}', toString(number)) AS event_id,
    concat('{{ SEED_RID_PREFIX }}', toString(number)) AS request_id,
    '{{ SEED_MODEL }}' AS model,
    '{{ SEED_KEY }}' AS key_id,
    100 AS prompt_tokens,
    50 AS completion_tokens,
    150 AS total_tokens,
    0.001 AS cost,
    now() - INTERVAL (number % 45) MINUTE AS timestamp
FROM numbers({{ SEED_ROW_COUNT }})
