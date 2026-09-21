-- Grafana "All" api_key expansion (subquery fragment).
(SELECT DISTINCT coalesce(nullIf(key_id, ''), nullIf(api_key_id, ''), 'unknown') FROM llm_gateway.request_log)
