-- dedupe-model-history.sh: pre-merge alias-row snapshot.
SELECT 'usage_log' AS t, model, count(), toFloat64(sum(cost)) FROM {{ DB }}.usage_log WHERE {{ MODEL_WHERE }} GROUP BY model
UNION ALL
SELECT 'billing_ledger', model_name, count(), toFloat64(sum(cost)) FROM {{ DB }}.billing_ledger WHERE {{ MODEL_NAME_WHERE }} GROUP BY model_name
UNION ALL
SELECT 'request_log', model, count(), toFloat64(0) FROM {{ DB }}.request_log WHERE {{ MODEL_WHERE }} GROUP BY model
ORDER BY t, model
FORMAT PrettyCompact
