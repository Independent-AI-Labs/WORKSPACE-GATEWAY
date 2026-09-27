-- backfill-request-log-model.sh: dry-run recoverability report.
-- Recoverable sources are the two authoritative stores that carry the model:
--   usage_log      keyed by request_id
--   billing_ledger keyed by event_id
SELECT
  countIf(model = '') AS empty_model,
  countIf(model = '' AND request_id IN (
    SELECT request_id FROM {{ DB }}.usage_log WHERE request_id != '' AND model != ''
  )) AS recoverable_via_usage_log,
  countIf(model = '' AND event_id IN (
    SELECT event_id FROM {{ DB }}.billing_ledger WHERE event_id != '' AND model_name != ''
  )) AS recoverable_via_billing_ledger,
  countIf(model = '' AND stream = 0 AND request_id IN (
    SELECT request_id FROM {{ DB }}.usage_log WHERE request_id != '' AND is_stream = 1
  )) AS stream_flag_recoverable
FROM {{ DB }}.request_log
FORMAT Vertical
