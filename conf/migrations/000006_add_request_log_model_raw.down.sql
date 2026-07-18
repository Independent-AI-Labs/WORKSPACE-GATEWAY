-- Reverse of 000006: drop model_raw from request_log. Historical data in
-- model_raw is discarded; model (canonical) is untouched.

ALTER TABLE llm_gateway.request_log
    DROP COLUMN IF EXISTS model_raw;
