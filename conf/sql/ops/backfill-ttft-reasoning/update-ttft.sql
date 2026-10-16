-- backfill-ttft-reasoning.sh: replace a thinking stream's late/absent content
-- TTFT with the first-byte (message_start) stamp. Anthropic reports no
-- separate reasoning-token count, so completion_tokens includes thinking; a
-- TTFT taken at the first visible answer token collapses the decode window to
-- the answer tail and inflates tok/s. The first byte precedes the first
-- generated token, so it is the closest stored proxy. Idempotent: only rows
-- still missing or later than the first-byte stamp are touched.
ALTER TABLE {{ DB }}.usage_log
UPDATE ttft_content_ms = ttft_first_byte_ms
WHERE is_stream = 1
  AND ttft_first_byte_ms > 0
  AND provider_id LIKE '%anthropic%'
  AND (ttft_content_ms = 0 OR ttft_content_ms > ttft_first_byte_ms)
  AND request_id IN (
      SELECT request_id
      FROM {{ DB }}.request_bodies
      WHERE position(resp_body, 'thinking_delta') > 0)
SETTINGS mutations_sync = 1