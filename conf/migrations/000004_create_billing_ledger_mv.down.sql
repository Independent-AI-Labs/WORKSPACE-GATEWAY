-- 000004_create_billing_ledger_mv.down.sql
-- Reverse of 000004: drop the Materialized View. billing_ledger rows
-- already written are NOT removed (the MV only forwards new inserts);
-- drop billing_ledger separately if a full reset is required.

DROP MATERIALIZED VIEW IF EXISTS llm_gateway.billing_ledger_mv;