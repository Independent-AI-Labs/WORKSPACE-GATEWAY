WITH per_provider AS (
    SELECT
        coalesce(nullIf(provider_id,''),'unknown') AS provider,
        count() AS requests,
        toInt64(sum(total_tokens)) AS tokens,
        sum(cost) AS cost
    FROM llm_gateway.usage_log
    WHERE {{ time_filter('timestamp') }} AND coalesce(nullIf(key_id,''), nullIf(api_key_id,''), 'unknown') IN ({{ gf_str_multi('api_key') }}) AND model IN ({{ gf_str_multi('model') }})
    GROUP BY provider
)
SELECT
    concat(
        provider, ' · ', toString(requests), ' req · ',
        multiIf(tokens >= 1000000000, concat(toString(round(tokens / 1000000000, 2)), 'B'),
                tokens >= 1000000, concat(toString(round(tokens / 1000000, 2)), 'M'),
                tokens >= 1000, concat(toString(round(tokens / 1000, 2)), 'K'),
                toString(tokens)),
        ' tok'
    ) AS name_str,
    round(cost, 2) AS value
FROM per_provider
ORDER BY cost DESC
