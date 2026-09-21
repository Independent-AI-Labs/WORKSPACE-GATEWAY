-- 000013_reported_cost_and_source_enum.up.sql
-- Separate the upstream-reported per-response cost from the billed cost, and
-- retire the `upstream`/`computed` provenance domain.
--
-- Billed `cost` is resolved solely from the provider-scoped price
-- (`pricing.overrides`, else models.dev in the declared namespace). The
-- upstream-reported value is metadata, never billed, so it is moved to the
-- new `reported_cost` column.
--
-- Ordering matters:
--   1. add reported_cost
--   2. copy the old upstream-reported cost into it (rows that were billed
--      from the upstream value are exactly cost_source='upstream')
--   3. collapse every row to 'unknown' so the enum can be reinterpreted
--   4. swap the enum domain. Cost/source are then rebuilt by
--      res/scripts/recalc-costs.sh --apply --all.
ALTER TABLE llm_gateway.usage_log
    ADD COLUMN IF NOT EXISTS reported_cost Float64 DEFAULT 0 AFTER cost_source;

ALTER TABLE llm_gateway.usage_log
    UPDATE reported_cost = cost WHERE cost_source = 'upstream'
    SETTINGS mutations_sync = 1;

ALTER TABLE llm_gateway.usage_log
    UPDATE cost_source = 'unknown' WHERE cost_source != 'unknown'
    SETTINGS mutations_sync = 1;

ALTER TABLE llm_gateway.usage_log
    MODIFY COLUMN cost_source
    Enum8('provider_override' = 0, 'models_dev' = 1, 'unknown' = 2) DEFAULT 2;
