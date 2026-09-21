-- Persist cache-write tokens so Anthropic-style cache_creation_input_tokens
-- can bill at the cache_write rate instead of the plain input rate
-- (SPEC-COST-CALC section 6). Also creates the append-only cost revaluation
-- audit used by res/scripts/recalc-costs.sh.

ALTER TABLE llm_gateway.usage_log
    ADD COLUMN IF NOT EXISTS cache_write_tokens UInt32 DEFAULT 0 AFTER cached_tokens;

ALTER TABLE llm_gateway.billing_ledger
    ADD COLUMN IF NOT EXISTS cache_write_tokens UInt32 DEFAULT 0 AFTER cached_tokens;

-- A materialized view's SELECT is frozen at creation, so it must be
-- recreated to carry the new column. Historical ledger rows keep zeros.
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
FROM llm_gateway.usage_log;

CREATE TABLE IF NOT EXISTS llm_gateway.cost_recalc_audit (
    event_id    String,
    provider_id LowCardinality(String) DEFAULT '',
    new_provider_id LowCardinality(String) DEFAULT '',
    model       LowCardinality(String) DEFAULT '',
    old_cost    Float64,
    new_cost    Float64,
    old_source  LowCardinality(String) DEFAULT '',
    run_id      String,
    timestamp   DateTime64(3) DEFAULT now()
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (event_id, run_id, timestamp)
TTL toDateTime(timestamp) + INTERVAL 13 MONTH;
