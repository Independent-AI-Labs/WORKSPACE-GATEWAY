-- Prod verify: request_log row count (res/scripts/gateway-prod.sh).
SELECT count() FROM {{ DB }}.request_log
