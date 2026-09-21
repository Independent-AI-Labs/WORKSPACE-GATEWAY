-- TTFT and stream-duration capture for usefulness telemetry
-- (REQ-USEFULNESS-TELEMETRY FR-1.6/FR-1.7).

ALTER TABLE llm_gateway.usage_log
    ADD COLUMN IF NOT EXISTS ttft_first_byte_ms UInt32 DEFAULT 0 AFTER is_stream;

ALTER TABLE llm_gateway.usage_log
    ADD COLUMN IF NOT EXISTS ttft_content_ms UInt32 DEFAULT 0 AFTER ttft_first_byte_ms;

ALTER TABLE llm_gateway.usage_log
    ADD COLUMN IF NOT EXISTS duration_ms UInt32 DEFAULT 0 AFTER ttft_content_ms;

-- Wire real timing into billing_ledger. A materialized view's SELECT is
-- frozen at creation, so the MV must be recreated. Ledger rows written
-- before this migration keep their historical zeros. NOTE: the migrate
-- driver splits on semicolons, so comments here must not contain them.
DROP TABLE IF EXISTS llm_gateway.billing_ledger_mv;

CREATE MATERIALIZED VIEW IF NOT EXISTS llm_gateway.billing_ledger_mv
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
    duration_ms             AS llm_latency_ms,
    ttft_content_ms         AS ttft_ms,
    ''                      AS upstream_resp_id,
    false                   AS redact_active,
    0                       AS redact_token_count,
    timestamp               AS timestamp
FROM llm_gateway.usage_log;

-- Rejection-language signals table written by the batch cruncher
-- (REQ-USEFULNESS-TELEMETRY FR-2.6).
CREATE TABLE IF NOT EXISTS llm_gateway.request_signals (
    request_id        String,
    model             LowCardinality(String) DEFAULT '',
    timestamp         DateTime64(3),
    is_followup       UInt8 DEFAULT 0,
    parsed            UInt8 DEFAULT 1,
    profane           UInt8 DEFAULT 0,
    profane_count     UInt16 DEFAULT 0,
    profane_terms     Array(String) DEFAULT [],
    frustrated        UInt8 DEFAULT 0,
    frustration_count UInt16 DEFAULT 0,
    frustration_terms Array(String) DEFAULT [],
    signal_count      UInt16 DEFAULT 0,
    signal_weight     Float32 DEFAULT 0,
    dict_version      LowCardinality(String) DEFAULT ''
)
ENGINE = ReplacingMergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (model, timestamp, request_id)
TTL toDateTime(timestamp) + INTERVAL 13 MONTH
SETTINGS index_granularity = 8192;
