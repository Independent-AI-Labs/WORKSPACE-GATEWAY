-- backfill-ttft-reasoning.sh: rows the repair would rewrite (read-only).
-- An Anthropic streaming generation whose response body carries a
-- thinking_delta had ttft_content_ms stamped at the first visible answer text
-- (after thinking) or never stamped at all, so it is missing or later than the
-- first-byte stamp. Those are the only rows affected.
SELECT count()
FROM {{ DB }}.usage_log AS u
WHERE u.is_stream = 1
  AND u.ttft_first_byte_ms > 0
  AND u.provider_id LIKE '%anthropic%'
  AND (u.ttft_content_ms = 0 OR u.ttft_content_ms > u.ttft_first_byte_ms)
  AND u.request_id IN (
      SELECT request_id
      FROM {{ DB }}.request_bodies
      WHERE position(resp_body, 'thinking_delta') > 0)
FORMAT TabSeparated