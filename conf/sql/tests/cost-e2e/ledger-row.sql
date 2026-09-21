-- billing_ledger row for one event id.
SELECT event_id, model_name, cost, prompt_tokens, total_tokens
FROM llm_gateway.billing_ledger
WHERE event_id = '{{ EID }}' LIMIT 1
