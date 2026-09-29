-- recalc-costs.sh: usage rows to repair.
SELECT event_id, request_id, toString(timestamp), provider_id, model,
       prompt_tokens, completion_tokens, total_tokens, cached_tokens,
       cache_write_tokens, reasoning_tokens, toString(cost_source), cost,
       cost_input_uncached, cost_cached, cost_cache_write, cost_output,
       cost_reasoning
FROM {{ DB }}.usage_log
WHERE {{ WHERE }}
ORDER BY timestamp
{{ LIMIT_CLAUSE }}
FORMAT TabSeparated
