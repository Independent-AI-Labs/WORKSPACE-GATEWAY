-- Distinct key hashes (usage_log preferred, request_log otherwise).
SELECT DISTINCT coalesce(nullIf(key_id, ''), nullIf(api_key_id, ''), 'unknown') AS k
FROM llm_gateway.{{ TABLE }}
ORDER BY k FORMAT TabSeparated
