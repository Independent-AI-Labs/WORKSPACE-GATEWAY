-- seed-clickhouse-dashboard-data.sh: drop prior usage_log seed rows.
ALTER TABLE {{ DB }}.usage_log DELETE WHERE request_id LIKE '{{ SEED_RID_PREFIX }}%'
