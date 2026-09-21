-- usage_log cost/token row for one request id.
SELECT cost_source, model, prompt_tokens, completion_tokens, total_tokens
FROM llm_gateway.usage_log
WHERE request_id = '{{ RID }}' LIMIT 1
