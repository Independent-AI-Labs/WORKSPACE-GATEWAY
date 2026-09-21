-- p4 error count (status >= 400) with the dashboard's key filter.
SELECT countIf(status >= 400) FROM llm_gateway.request_log
WHERE timestamp >= toDateTime('{{ FROM_TS }}') AND timestamp <= toDateTime('{{ TO_TS }}')
  AND coalesce(nullIf(key_id, ''), nullIf(api_key_id, ''), 'unknown') IN ({{ KEYS }})
