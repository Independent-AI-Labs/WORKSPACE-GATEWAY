-- 000005_add_model_raw.up.sql
-- Add model_raw (verbatim model string as seen on the wire) to usage_log
-- and billing_ledger, and recreate billing_ledger_mv so new inserts
-- forward it. model/model_name remain the CANONICAL id (see
-- conf/model-registry.yaml). Idempotent.

ALTER TABLE llm_gateway.usage_log
    ADD COLUMN IF NOT EXISTS model_raw LowCardinality(String) DEFAULT '' AFTER model;

ALTER TABLE llm_gateway.billing_ledger
    ADD COLUMN IF NOT EXISTS model_raw LowCardinality(String) DEFAULT '' AFTER model_name;

DROP VIEW IF EXISTS llm_gateway.billing_ledger_mv;

CREATE MATERIALIZED VIEW llm_gateway.billing_ledger_mv
TO llm_gateway.billing_ledger
AS
SELECT
    event_id                AS event_id,
    ''                      AS tenant_id,
    ''                      AS user_id,
    'opencode'              AS provider,
    model                   AS model_name,
    model_raw               AS model_raw,
    ''                      AS route_name,
    ''                      AS consumer_group,
    if(is_stream = 1, 'stream', 'batch')  AS request_mode,
    if(cached_tokens > 0, 'hit', 'miss')  AS cache_status,
    prompt_tokens           AS prompt_tokens,
    completion_tokens       AS completion_tokens,
    reasoning_tokens        AS reasoning_tokens,
    cached_tokens           AS cached_tokens,
    total_tokens            AS total_tokens,
    CAST(0 AS Decimal64(8)) AS rate_input,
    CAST(0 AS Decimal64(8)) AS rate_output,
    'USD'                   AS currency,
    CAST(round(cost, 6) AS Decimal64(6)) AS cost,
    (aborted = 0)           AS success,
    if(aborted > 0, 'aborted', '') AS error_type,
    0                       AS llm_latency_ms,
    0                       AS ttft_ms,
    ''                      AS upstream_resp_id,
    false                   AS redact_active,
    0                       AS redact_token_count,
    timestamp               AS timestamp
FROM llm_gateway.usage_log;
