-- billing_ledger_mv definition, kept in lock-step with conf/sql/clickhouse-init.sql
-- and conf/sql/migrations/000012_add_cache_write_tokens.up.sql (asserted by
-- tests/config/test_reconcile_model_attribution.sh).
CREATE MATERIALIZED VIEW IF NOT EXISTS {{ DB }}.billing_ledger_mv
TO {{ DB }}.billing_ledger
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
    cache_write_tokens      AS cache_write_tokens,
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
FROM {{ DB }}.usage_log;
