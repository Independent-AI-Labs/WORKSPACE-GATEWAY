-- 000011: tiered retention (REQ-SECURITY-HARDENING FR-4). Removes every
-- deletion TTL and replaces retention with tiered compression on storage
-- policy `tiered` (conf/clickhouse-storage-tiering.xml): parts move to the
-- `archive` volume and recompress CODEC ZSTD(3). Bodies tier at 6 months,
-- metadata at 12, both recompress at 18. Nothing is ever deleted.

ALTER TABLE llm_gateway.request_log
    MODIFY SETTING storage_policy = 'tiered';
ALTER TABLE llm_gateway.request_log
    MODIFY TTL toDateTime(timestamp) + INTERVAL 12 MONTH TO VOLUME 'archive',
               toDateTime(timestamp) + INTERVAL 18 MONTH RECOMPRESS CODEC(ZSTD(3));

ALTER TABLE llm_gateway.request_bodies
    MODIFY SETTING storage_policy = 'tiered';
ALTER TABLE llm_gateway.request_bodies
    MODIFY TTL toDateTime(timestamp) + INTERVAL 6 MONTH TO VOLUME 'archive',
               toDateTime(timestamp) + INTERVAL 18 MONTH RECOMPRESS CODEC(ZSTD(3));

ALTER TABLE llm_gateway.usage_log
    MODIFY SETTING storage_policy = 'tiered';
ALTER TABLE llm_gateway.usage_log
    MODIFY TTL toDateTime(timestamp) + INTERVAL 12 MONTH TO VOLUME 'archive',
               toDateTime(timestamp) + INTERVAL 18 MONTH RECOMPRESS CODEC(ZSTD(3));

ALTER TABLE llm_gateway.billing_ledger
    MODIFY SETTING storage_policy = 'tiered';
ALTER TABLE llm_gateway.billing_ledger
    MODIFY TTL toDateTime(timestamp) + INTERVAL 12 MONTH TO VOLUME 'archive',
               toDateTime(timestamp) + INTERVAL 18 MONTH RECOMPRESS CODEC(ZSTD(3));

ALTER TABLE llm_gateway.billing_discrepancies
    MODIFY SETTING storage_policy = 'tiered';
ALTER TABLE llm_gateway.billing_discrepancies
    MODIFY TTL toDateTime(flagged_at) + INTERVAL 12 MONTH TO VOLUME 'archive',
               toDateTime(flagged_at) + INTERVAL 18 MONTH RECOMPRESS CODEC(ZSTD(3));

ALTER TABLE llm_gateway.request_signals
    MODIFY SETTING storage_policy = 'tiered';
ALTER TABLE llm_gateway.request_signals
    MODIFY TTL toDateTime(timestamp) + INTERVAL 12 MONTH TO VOLUME 'archive',
               toDateTime(timestamp) + INTERVAL 18 MONTH RECOMPRESS CODEC(ZSTD(3));
