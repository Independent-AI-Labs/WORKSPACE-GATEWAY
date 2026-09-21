-- usage_log cost row for one request id.
SELECT event_id, cost_source, cost, model, prompt_tokens, completion_tokens, total_tokens
FROM llm_gateway.usage_log
WHERE request_id = '{{ RID }}' LIMIT 1
