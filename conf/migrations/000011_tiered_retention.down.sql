-- 000011 down: restore the historical 13-month deletion TTLs and the
-- default storage policy. NOTE: if parts already moved to the `archive`
-- volume, ClickHouse refuses the policy downgrade (parts cannot move back
-- to a smaller policy), the down migration then fails loudly - restore
-- from backup instead. Nothing deletes data on the way down, the 13-month
-- TTL only resumes expiring rows older than that once reapplied.

ALTER TABLE llm_gateway.request_log
    MODIFY TTL toDateTime(timestamp) + INTERVAL 13 MONTH;
ALTER TABLE llm_gateway.usage_log
    MODIFY TTL toDateTime(timestamp) + INTERVAL 13 MONTH;
ALTER TABLE llm_gateway.billing_ledger
    MODIFY TTL toDateTime(timestamp) + INTERVAL 13 MONTH;
ALTER TABLE llm_gateway.request_signals
    MODIFY TTL toDateTime(timestamp) + INTERVAL 13 MONTH;

ALTER TABLE llm_gateway.request_bodies REMOVE TTL;
ALTER TABLE llm_gateway.billing_discrepancies REMOVE TTL;

ALTER TABLE llm_gateway.request_log      MODIFY SETTING storage_policy = 'default';
ALTER TABLE llm_gateway.request_bodies   MODIFY SETTING storage_policy = 'default';
ALTER TABLE llm_gateway.usage_log        MODIFY SETTING storage_policy = 'default';
ALTER TABLE llm_gateway.billing_ledger   MODIFY SETTING storage_policy = 'default';
ALTER TABLE llm_gateway.billing_discrepancies MODIFY SETTING storage_policy = 'default';
ALTER TABLE llm_gateway.request_signals  MODIFY SETTING storage_policy = 'default';
