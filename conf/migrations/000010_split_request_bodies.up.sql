-- 000010: conversation-body isolation (REQ-SECURITY-HARDENING FR-3).
-- Bodies move to a dedicated request_bodies table that carries no grant
-- for grafana_ro. request_log keeps metadata only. Idempotent, the drop of
-- the body columns is gated on a copy-parity check that aborts the
-- migration (throws) on mismatch.

CREATE TABLE IF NOT EXISTS llm_gateway.request_bodies
(
    event_id  String,
    request_id String DEFAULT '',
    req_body  String DEFAULT '',
    resp_body String DEFAULT '',
    timestamp DateTime64(3) DEFAULT now()
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (event_id, request_id, timestamp)
SETTINGS index_granularity = 8192,
         parts_to_delay_insert = 500,
         parts_to_throw_insert = 1000,
         inactive_parts_to_delay_insert = 500,
         inactive_parts_to_throw_insert = 1000,
         max_parts_in_total = 5000;

-- Copy historical bodies (only rows that carry a body).
INSERT INTO llm_gateway.request_bodies
SELECT event_id, request_id, req_body, resp_body, timestamp
FROM llm_gateway.request_log
WHERE req_body != '' OR resp_body != '';

-- Parity gate: fail the migration instead of dropping bodies on mismatch.
SELECT throwIf(
    (SELECT count() FROM llm_gateway.request_log WHERE req_body != '' OR resp_body != '')
    != (SELECT count() FROM llm_gateway.request_bodies),
    '000010 parity check failed: request_bodies row count != request_log body row count'
);

ALTER TABLE llm_gateway.request_log DROP COLUMN IF EXISTS req_body;
ALTER TABLE llm_gateway.request_log DROP COLUMN IF EXISTS resp_body;
