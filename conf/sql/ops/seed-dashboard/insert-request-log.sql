-- seed-clickhouse-dashboard-data.sh: deterministic request_log rows, mixed
-- status codes (200/401/404/500), populated model/key.
INSERT INTO {{ DB }}.request_log (
    provider, method, uri, status, model, key_id, request_id,
    upstream_response_time_s, timestamp
)
SELECT
    'integration-seed' AS provider,
    'POST' AS method,
    '/v1/chat/completions' AS uri,
    multiIf(
        number % 10 = 0, 401,
        number % 7 = 0, 404,
        number % 13 = 0, 500,
        200
    ) AS status,
    '{{ SEED_MODEL }}' AS model,
    '{{ SEED_KEY }}' AS key_id,
    concat('{{ SEED_RID_PREFIX }}', toString(number)) AS request_id,
    0.05 + (number % 10) * 0.01 AS upstream_response_time_s,
    now() - INTERVAL (number % 45) MINUTE AS timestamp
FROM numbers({{ SEED_ROW_COUNT }})
