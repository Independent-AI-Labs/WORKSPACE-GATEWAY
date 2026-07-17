CREATE DATABASE IF NOT EXISTS llm_gateway;

CREATE TABLE IF NOT EXISTS llm_gateway.request_log (
    event_id                  String DEFAULT '',
    provider                  LowCardinality(String),
    model                     LowCardinality(String) DEFAULT '',
    stream                    Bool DEFAULT false,
    method                    LowCardinality(String),
    uri                       String,
    status                    UInt16,
    upstream_response_time_s  Float64 DEFAULT 0,
    request_size              UInt32 DEFAULT 0,
    response_size             UInt32 DEFAULT 0,
    client_ip                 String DEFAULT '0.0.0.0',
    api_key_id                String DEFAULT '',
    tenant_id                 LowCardinality(String) DEFAULT '',
    user_id                   String DEFAULT '',
    key_id                    String DEFAULT '',
    session_id                String DEFAULT '',
    request_id                String DEFAULT '',
    project_id                String DEFAULT '',
    parent_session_id         String DEFAULT '',
    client_type               LowCardinality(String) DEFAULT '',
    agent_name                LowCardinality(String) DEFAULT '',
    opencode_version          LowCardinality(String) DEFAULT '',
    user_agent                String DEFAULT '',
    prompt_tokens             UInt32 DEFAULT 0,
    completion_tokens         UInt32 DEFAULT 0,
    total_tokens              UInt32 DEFAULT 0,
    req_body                  String DEFAULT '',
    resp_body                 String DEFAULT '',
    redact_active             Bool DEFAULT false,
    redact_token_count        UInt32 DEFAULT 0,
    timestamp                 DateTime64(3) DEFAULT now()
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (provider, model, timestamp)
TTL toDateTime(timestamp) + INTERVAL 13 MONTH
SETTINGS index_granularity = 8192;

CREATE TABLE IF NOT EXISTS llm_gateway.usage_log (
    event_id                  String,
    request_id                String DEFAULT '',
    model                     LowCardinality(String) DEFAULT '',
    model_raw                 LowCardinality(String) DEFAULT '',
    prompt_tokens             UInt32 DEFAULT 0,
    completion_tokens         UInt32 DEFAULT 0,
    total_tokens              UInt32 DEFAULT 0,
    cached_tokens             UInt32 DEFAULT 0,
    reasoning_tokens          UInt32 DEFAULT 0,
    key_id                    String DEFAULT '',
    api_key_id                String DEFAULT '',
    aborted                   UInt8 DEFAULT 0,
    is_stream                 UInt8 DEFAULT 0,
    cost                      Float64 DEFAULT 0,
    cost_source               Enum8('upstream' = 0, 'computed' = 1, 'unknown' = 2) DEFAULT 2,
    timestamp                 DateTime64(3) DEFAULT now()
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (event_id, request_id, timestamp)
TTL toDateTime(timestamp) + INTERVAL 13 MONTH
SETTINGS index_granularity = 8192;

CREATE TABLE IF NOT EXISTS llm_gateway.billing_ledger (
    event_id          String,
    tenant_id         LowCardinality(String),
    user_id           String,
    provider          LowCardinality(String),
    model_name        LowCardinality(String),
    model_raw         LowCardinality(String) DEFAULT '',
    route_name        LowCardinality(String),
    consumer_group    LowCardinality(String),
    request_mode      LowCardinality(String),
    cache_status      LowCardinality(String),
    prompt_tokens     UInt32,
    completion_tokens UInt32,
    reasoning_tokens  UInt32,
    cached_tokens     UInt32,
    total_tokens      UInt32,
    rate_input        Decimal64(8),
    rate_output       Decimal64(8),
    currency          LowCardinality(String),
    cost              Decimal64(6),
    success           Bool,
    error_type        LowCardinality(String),
    llm_latency_ms    UInt32,
    ttft_ms           UInt32,
    upstream_resp_id  LowCardinality(String),
    redact_active     Bool DEFAULT false,
    redact_token_count UInt32 DEFAULT 0,
    timestamp         DateTime64(3) DEFAULT now()
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (tenant_id, user_id, timestamp)
TTL toDateTime(timestamp) + INTERVAL 13 MONTH
SETTINGS index_granularity = 8192;

CREATE TABLE IF NOT EXISTS llm_gateway.billing_discrepancies (
    date             Date,
    tenant_id        LowCardinality(String),
    provider         LowCardinality(String),
    model_name       LowCardinality(String),
    gateway_tokens   UInt32,
    provider_tokens  UInt32,
    divergence       Decimal64(6),
    tolerance        Decimal64(6),
    flagged_at       DateTime64(3) DEFAULT now()
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (date, tenant_id, provider, model_name);

ALTER TABLE llm_gateway.request_log
    ADD COLUMN IF NOT EXISTS tenant_id         LowCardinality(String) DEFAULT '' AFTER api_key_id;

ALTER TABLE llm_gateway.request_log
    ADD COLUMN IF NOT EXISTS user_id           String DEFAULT '' AFTER tenant_id;

ALTER TABLE llm_gateway.request_log
    ADD COLUMN IF NOT EXISTS key_id            String DEFAULT '' AFTER user_id;

ALTER TABLE llm_gateway.request_log
    ADD COLUMN IF NOT EXISTS session_id        String DEFAULT '' AFTER key_id;

ALTER TABLE llm_gateway.request_log
    ADD COLUMN IF NOT EXISTS request_id        String DEFAULT '' AFTER session_id;

ALTER TABLE llm_gateway.request_log
    ADD COLUMN IF NOT EXISTS project_id        String DEFAULT '' AFTER request_id;

ALTER TABLE llm_gateway.request_log
    ADD COLUMN IF NOT EXISTS parent_session_id String DEFAULT '' AFTER project_id;

ALTER TABLE llm_gateway.request_log
    ADD COLUMN IF NOT EXISTS client_type       LowCardinality(String) DEFAULT '' AFTER parent_session_id;

ALTER TABLE llm_gateway.request_log
    ADD COLUMN IF NOT EXISTS agent_name        LowCardinality(String) DEFAULT '' AFTER client_type;

ALTER TABLE llm_gateway.request_log
    ADD COLUMN IF NOT EXISTS opencode_version  LowCardinality(String) DEFAULT '' AFTER agent_name;

ALTER TABLE llm_gateway.request_log
    ADD COLUMN IF NOT EXISTS user_agent        String DEFAULT '' AFTER opencode_version;

ALTER TABLE llm_gateway.usage_log
    ADD COLUMN IF NOT EXISTS cached_tokens    UInt32 DEFAULT 0 AFTER total_tokens;

ALTER TABLE llm_gateway.usage_log
    ADD COLUMN IF NOT EXISTS reasoning_tokens UInt32 DEFAULT 0 AFTER cached_tokens;

ALTER TABLE llm_gateway.usage_log
    ADD COLUMN IF NOT EXISTS key_id           String DEFAULT '' AFTER reasoning_tokens;

ALTER TABLE llm_gateway.usage_log
    ADD COLUMN IF NOT EXISTS api_key_id       String DEFAULT '' AFTER key_id;

ALTER TABLE llm_gateway.usage_log
    ADD COLUMN IF NOT EXISTS aborted          UInt8 DEFAULT 0 AFTER api_key_id;

ALTER TABLE llm_gateway.usage_log
    ADD COLUMN IF NOT EXISTS is_stream        UInt8 DEFAULT 0 AFTER aborted;

ALTER TABLE llm_gateway.usage_log
    ADD COLUMN IF NOT EXISTS cost             Float64 DEFAULT 0 AFTER is_stream;

ALTER TABLE llm_gateway.usage_log
    ADD COLUMN IF NOT EXISTS cost_source      Enum8('upstream' = 0, 'computed' = 1, 'unknown' = 2) DEFAULT 2 AFTER cost;

ALTER TABLE llm_gateway.usage_log
    ADD COLUMN IF NOT EXISTS request_id      String DEFAULT '' AFTER event_id;

ALTER TABLE llm_gateway.usage_log
    ADD COLUMN IF NOT EXISTS model_raw       LowCardinality(String) DEFAULT '' AFTER model;

ALTER TABLE llm_gateway.billing_ledger
    ADD COLUMN IF NOT EXISTS model_raw       LowCardinality(String) DEFAULT '' AFTER model_name;

-- billing_ledger write pipeline: Materialized View populates billing_ledger
-- automatically from every usage_log INSERT. Columns only available in
-- request_log (tenant_id, user_id, provider, route_name, llm_latency_ms,
-- ttft_ms, upstream_resp_id) are left as defaults here; a future enrich
-- job can backfill them via the request_id join key. rate_input/rate_output
-- require the models.dev pricing cache (in nginx shared dict, not
-- ClickHouse), so they default to 0 until a reconciler copy of the
-- pricing snapshot lands in ClickHouse.
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
    0                       AS llm_latency_ms,
    0                       AS ttft_ms,
    ''                      AS upstream_resp_id,
    false                   AS redact_active,
    0                       AS redact_token_count,
    timestamp               AS timestamp
FROM llm_gateway.usage_log;
