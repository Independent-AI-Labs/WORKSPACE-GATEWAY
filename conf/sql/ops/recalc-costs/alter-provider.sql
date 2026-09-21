-- recalc-costs.sh: one provider_id backfill per (old -> new, route) mapping.
ALTER TABLE {{ DB }}.usage_log
UPDATE provider_id = {{ NEW_PID }}
WHERE {{ PREDICATE }}
  AND provider_id != {{ NEW_PID }}
  AND cost_source IN ({{ SOURCE_SQL }})
SETTINGS mutations_sync = 1
