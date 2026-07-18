-- 000006_add_request_log_model_raw.up.sql
-- Add model_raw (verbatim model string as seen on the wire) to request_log,
-- matching usage_log/billing_ledger (000005). model remains the CANONICAL
-- id (see conf/model-registry.yaml); model_raw is the audit trail that lets
-- historical rows be re-bucketed when the registry changes. Idempotent.

ALTER TABLE llm_gateway.request_log
    ADD COLUMN IF NOT EXISTS model_raw LowCardinality(String) DEFAULT '' AFTER model;
