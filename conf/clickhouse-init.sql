CREATE DATABASE IF NOT EXISTS llm_gateway;

CREATE TABLE IF NOT EXISTS llm_gateway.request_log (
    event_id          String,
    provider          LowCardinality(String),
    model             LowCardinality(String),
    stream            Bool,
    method            LowCardinality(String),
    uri               String,
    status            UInt16,
    latency_ms        UInt32,
    request_size      UInt32,
    response_size     UInt32,
    client_ip         IPv4,
    api_key_id        String,
    redact_active     Bool DEFAULT false,
    redact_token_count UInt32 DEFAULT 0,
    timestamp         DateTime64(3) DEFAULT now()
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (provider, model, timestamp)
TTL timestamp + INTERVAL 13 MONTH
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
TTL timestamp + INTERVAL 13 MONTH
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
