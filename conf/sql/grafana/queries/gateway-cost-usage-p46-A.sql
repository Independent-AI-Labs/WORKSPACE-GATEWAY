SELECT
    coalesce(nullIf(provider_id,''),'unknown') AS "provider",
    round(sum(cost), 2) AS "usd"
FROM llm_gateway.usage_log
WHERE {{ time_filter('timestamp') }}
  AND coalesce(nullIf(key_id,''), nullIf(api_key_id,''), 'unknown') IN ({{ gf_str_multi('api_key') }})
  AND model IN ({{ gf_str_multi('model') }})
GROUP BY "provider"
ORDER BY "usd" DESC
