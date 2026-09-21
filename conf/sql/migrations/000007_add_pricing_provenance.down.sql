-- 000007_add_pricing_provenance.down.sql
ALTER TABLE llm_gateway.usage_log
    DROP COLUMN IF EXISTS pricing_snapshot,
    DROP COLUMN IF EXISTS pricing_source,
    DROP COLUMN IF EXISTS provider_id;
