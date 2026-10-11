-- 000017: WORKSPACE-RP knowledge-store logs (W8: a Vector source for the new
-- service). Vector's journald source tails the workspace-rp.service unit and
-- writes structured rows here as vector_rw. One table for every RP process
-- log (PostgreSQL and the postgres-exporter); the service column separates
-- them. Idempotent: safe on fresh volumes and via `make ch-migrate`.

CREATE TABLE IF NOT EXISTS llm_gateway.service_log
(
    service   LowCardinality(String),
    unit      LowCardinality(String) DEFAULT '',
    container LowCardinality(String) DEFAULT '',
    level     LowCardinality(String) DEFAULT '',
    pid       Int32 DEFAULT 0,
    message   String DEFAULT '',
    timestamp DateTime64(3) DEFAULT now()
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (service, timestamp)
TTL toDateTime(timestamp) + INTERVAL 13 MONTH
SETTINGS index_granularity = 8192,
         parts_to_delay_insert = 500,
         parts_to_throw_insert = 1000,
         inactive_parts_to_delay_insert = 500,
         inactive_parts_to_throw_insert = 1000,
         max_parts_in_total = 5000;