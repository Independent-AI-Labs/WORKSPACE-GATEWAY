-- backfill-ttft-reasoning.sh: post-repair posture. `remaining` MUST be 0
-- (idempotent, nothing left to correct); `corrected` counts Anthropic thinking
-- streams now carrying the first-byte TTFT.
SELECT
    (SELECT count()
     FROM {{ DB }}.usage_log AS u
     WHERE u.is_stream = 1
       AND u.ttft_first_byte_ms > 0
       AND u.provider_id LIKE '%anthropic%'
       AND (u.ttft_content_ms = 0 OR u.ttft_content_ms > u.ttft_first_byte_ms)
       AND u.request_id IN (
           SELECT request_id FROM {{ DB }}.request_bodies
           WHERE position(resp_body, 'thinking_delta') > 0)) AS remaining,
    (SELECT count()
     FROM {{ DB }}.usage_log AS u
     WHERE u.is_stream = 1
       AND u.ttft_content_ms = u.ttft_first_byte_ms
       AND u.provider_id LIKE '%anthropic%'
       AND u.request_id IN (
           SELECT request_id FROM {{ DB }}.request_bodies
           WHERE position(resp_body, 'thinking_delta') > 0)) AS corrected
FORMAT TabSeparatedWithNames