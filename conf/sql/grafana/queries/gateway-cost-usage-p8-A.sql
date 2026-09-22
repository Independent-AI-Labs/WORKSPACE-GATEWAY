WITH per_model AS (
    SELECT
        model,
        toInt64(sum(total_tokens)) AS tokens,
        sum(cost) AS cost
    FROM llm_gateway.usage_log
    WHERE {{ time_filter('timestamp') }} AND model != '' AND coalesce(nullIf(key_id,''), nullIf(api_key_id,''), 'unknown') IN ({{ gf_str_multi('api_key') }}) AND model IN ({{ gf_str_multi('model') }})
    GROUP BY model
    ORDER BY tokens DESC
    LIMIT 20
)
SELECT
    model,
    tokens,
    round(cost, 2) AS cost
FROM per_model
ORDER BY tokens DESC
