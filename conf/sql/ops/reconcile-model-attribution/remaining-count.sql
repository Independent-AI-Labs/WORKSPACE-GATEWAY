-- Rows still missing a model after the reconcile.
SELECT
    (SELECT count() FROM {{ DB }}.request_log
     WHERE model = '' AND (uri LIKE '%chat/completions%' OR uri LIKE '%/responses%'))
  + (SELECT count() FROM {{ DB }}.usage_log WHERE model = '')
  + (SELECT count() FROM {{ DB }}.billing_ledger WHERE model_name = '')
