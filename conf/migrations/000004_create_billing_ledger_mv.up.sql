-- 000004_create_billing_ledger_mv.up.sql
-- Create a Materialized View that auto-populates billing_ledger on every
-- usage_log INSERT. Columns only available in request_log (tenant_id,
-- user_id, route_name, llm_latency_ms, ttft_ms, upstream_resp_id) default
-- to empty/0 here - a future enrich job can backfill them via the
-- request_id join key. rate_input/rate_output require the models.dev
-- pricing cache (in nginx shared dict, not ClickHouse), so they default
-- to 0 until a reconciler pricing snapshot lands in ClickHouse.
--
-- This migration replicates the canonical MV declared in
-- conf/clickhouse-init.sql lines 174-212 so databases that pre-date the
-- MV (or that were provisioned before billing_ledger existed) get it on
-- the next `make ch-migrate`. Idempotent.

CREATE MATERIALIZED VIEW IF NOT EXISTS llm_gateway.billing_ledger_mv
TO llm_gateway.billing_ledger
AS
SELECT
    event_id                AS event_id,
    ''                      AS tenant_id,
    ''                      AS user_id,
    'opencode'              AS provider,
    model                   AS model_name,
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