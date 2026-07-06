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
    model                     LowCardinality(String) DEFAULT '',
    prompt_tokens             UInt32 DEFAULT 0,
    completion_tokens         UInt32 DEFAULT 0,
    total_tokens              UInt32 DEFAULT 0,
    timestamp                 DateTime64(3) DEFAULT now()
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (event_id, timestamp)
TTL toDateTime(timestamp) + INTERVAL 13 MONTH
SETTINGS index_granularity = 8192;

CREATE TABLE IF NOT EXISTS llm_gateway.billing_ledger (
    event_id          String,
    tenant_id         LowCardinality(String),
    user_id           String,
    provider          LowCardinality(String),
    model_name        LowCardinality(String),
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
