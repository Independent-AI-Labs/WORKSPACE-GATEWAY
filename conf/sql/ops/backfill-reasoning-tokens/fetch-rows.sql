-- Rows carrying reasoning_content in the SSE body (backfill-reasoning-tokens.sh).
SELECT event_id, model, key_id, toString(timestamp) AS ts, resp_body
FROM {{ DB }}.request_log
WHERE resp_body LIKE '%reasoning_content":%'
  AND event_id != ''
  AND timestamp >= '{{ CUTOFF }}'
ORDER BY timestamp DESC
{{ LIMIT_CLAUSE }}
FORMAT JSONEachRow
