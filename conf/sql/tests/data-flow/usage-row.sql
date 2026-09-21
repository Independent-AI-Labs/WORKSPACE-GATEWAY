-- usage_log token row for one request id.
SELECT request_id, model, prompt_tokens, completion_tokens, total_tokens
FROM llm_gateway.usage_log
WHERE request_id = '{{ RID }}' LIMIT 1
