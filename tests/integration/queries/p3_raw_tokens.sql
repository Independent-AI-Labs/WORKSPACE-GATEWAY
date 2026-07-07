SELECT
    toInt64(sum(total_tokens)) as total_tok,
    toInt64(sum(prompt_tokens - cached_tokens)) as input_tok,
    toInt64(sum(cached_tokens)) as cached_tok,
    toInt64(sum(completion_tokens - reasoning_tokens)) as output_tok,
    toInt64(sum(reasoning_tokens)) as reasoning_tok
FROM llm_gateway.usage_log
WHERE timestamp >= toDateTime(__FROM__) AND timestamp <= toDateTime(__TO__) AND coalesce(nullIf(key_id,''), nullIf(api_key_id,''), 'unknown') IN (__API_KEYS__) AND model IN (__MODELS__)
