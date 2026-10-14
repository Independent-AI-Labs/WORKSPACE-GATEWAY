WITH per_model AS (
    SELECT
        model,
        toInt64(sum(total_tokens)) AS tokens,
        sum(cost) AS cost,
        count() AS requests,
        sum(greatest(prompt_tokens - cached_tokens - cache_write_tokens, 0)) AS input_tok,
        sum(cached_tokens) AS cached_tok,
        sum(greatest(completion_tokens - reasoning_tokens, 0)) AS output_tok,
        sum(cost_input_uncached) AS input_cost,
        sum(cost_cached) AS cached_cost,
        sum(cost_output) AS output_cost
    FROM llm_gateway.usage_log
    WHERE {{ time_filter('timestamp') }} AND model != '' AND coalesce(nullIf(key_id,''), nullIf(api_key_id,''), 'unknown') IN ({{ gf_str_multi('api_key') }}) AND model IN ({{ gf_str_multi('model') }})
    GROUP BY model
    ORDER BY tokens DESC
    LIMIT 20
)
SELECT
    model,
    tokens,
    round(cost, 2) AS cost,
    requests,
    round(input_cost / nullIf(input_tok, 0) * 1000000, 4) AS rate_input,
    round(cached_cost / nullIf(cached_tok, 0) * 1000000, 4) AS rate_cached,
    round(output_cost / nullIf(output_tok, 0) * 1000000, 4) AS rate_output,
    round(cost / nullIf(requests, 0), 6) AS avg_cost
FROM per_model
ORDER BY tokens DESC