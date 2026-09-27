-- backfill-request-log-model.sh: post-reconcile attribution snapshot.
SELECT 'request_log' AS t, count() AS rows, countIf(model = '') AS empty_model,
       countIf(model_raw = '') AS empty_raw
FROM {{ DB }}.request_log
UNION ALL
SELECT 'usage_log', count(), countIf(model = ''), countIf(model_raw = '')
FROM {{ DB }}.usage_log
UNION ALL
SELECT 'billing_ledger', count(), countIf(model_name = ''), countIf(model_raw = '')
FROM {{ DB }}.billing_ledger
ORDER BY 1
FORMAT PrettyCompact
