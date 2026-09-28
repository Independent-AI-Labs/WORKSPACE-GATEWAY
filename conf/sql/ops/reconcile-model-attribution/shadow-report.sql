-- reconcile-model-attribution.sh: dry-run post-state of the shadow copies,
-- so the repair is inspected BEFORE any EXCHANGE touches a live table.
SELECT 'request_log' AS t, count() AS rows,
       countIf(model = '') AS empty_model,
       countIf(model_raw = '') AS empty_raw,
       countIf(model_raw != '' AND match(model_raw, '^[A-Za-z0-9._/-]+$') = 0) AS bad_raw
FROM {{ DB }}.request_log_backfill
UNION ALL
SELECT 'usage_log', count(), countIf(model = ''), countIf(model_raw = ''),
       countIf(model_raw != '' AND match(model_raw, '^[A-Za-z0-9._/-]+$') = 0)
FROM {{ DB }}.usage_log_backfill
UNION ALL
SELECT 'billing_ledger', count(), countIf(model_name = ''), countIf(model_raw = ''),
       countIf(model_raw != '' AND match(model_raw, '^[A-Za-z0-9._/-]+$') = 0)
FROM {{ DB }}.billing_ledger_backfill
ORDER BY 1
FORMAT PrettyCompact
