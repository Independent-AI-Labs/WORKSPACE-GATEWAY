-- p15 total cost with the dashboard's key/model filters.
SELECT round(sum(cost), 6) FROM llm_gateway.usage_log
WHERE timestamp >= toDateTime('{{ FROM_TS }}') AND timestamp <= toDateTime('{{ TO_TS }}')
  AND coalesce(nullIf(key_id, ''), nullIf(api_key_id, ''), 'unknown') IN ({{ KEYS }})
  AND model IN ({{ MODELS }})
