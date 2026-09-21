-- p14 total streams with the dashboard's key/model filters.
SELECT count() FROM llm_gateway.usage_log
WHERE timestamp >= toDateTime('{{ FROM_TS }}') AND timestamp <= toDateTime('{{ TO_TS }}')
  AND coalesce(nullIf(key_id, ''), nullIf(api_key_id, ''), 'unknown') IN ({{ KEYS }})
  AND is_stream = 1
