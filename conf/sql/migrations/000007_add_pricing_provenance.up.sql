-- 000007_add_pricing_provenance.up.sql
-- Preserve provider identity and the pricing snapshot used for each usage row.
ALTER TABLE llm_gateway.usage_log
    ADD COLUMN IF NOT EXISTS provider_id LowCardinality(String) DEFAULT '' AFTER cost_source,
    ADD COLUMN IF NOT EXISTS pricing_source LowCardinality(String) DEFAULT '' AFTER provider_id,
    ADD COLUMN IF NOT EXISTS pricing_snapshot String DEFAULT '' AFTER pricing_source;