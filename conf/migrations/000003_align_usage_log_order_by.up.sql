-- 000003_align_usage_log_order_by.up.sql
-- Intended to change usage_log ORDER BY from (event_id, timestamp) to
-- (event_id, request_id, timestamp) for ASOF JOIN performance on
-- request_id. ClickHouse 24.8 cannot MODIFY ORDER BY on a populated
-- MergeTree table (OPERATION_NOT_SUPPORTED), so this migration is a
-- documented no-op: fresh installs already get the correct ORDER BY from
-- conf/clickhouse-init.sql, and existing installs keep the existing ORDER
-- BY (forward requests still align via request_id indexes/queries).
--
-- Recorded in schema_migrations so the framework has a complete
-- audit trail and so re-running `up` skips it as already-applied.

SELECT 1;