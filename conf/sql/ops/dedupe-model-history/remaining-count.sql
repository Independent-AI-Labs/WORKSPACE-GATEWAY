-- dedupe-model-history.sh: alias rows still present after the merge.
SELECT
  (SELECT count() FROM {{ DB }}.usage_log WHERE {{ MODEL_WHERE }})
  + (SELECT count() FROM {{ DB }}.billing_ledger WHERE {{ MODEL_NAME_WHERE }})
  + (SELECT count() FROM {{ DB }}.request_log WHERE {{ MODEL_WHERE }})
