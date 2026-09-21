-- recalc-costs.sh: existing audit tables predate the provider-backfill column.
ALTER TABLE {{ DB }}.cost_recalc_audit
    ADD COLUMN IF NOT EXISTS new_provider_id LowCardinality(String) DEFAULT ''
