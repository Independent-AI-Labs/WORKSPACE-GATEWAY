-- seed-clickhouse-dashboard-data.sh: drop prior request_log seed rows.
ALTER TABLE {{ DB }}.request_log DELETE WHERE request_id LIKE '{{ SEED_RID_PREFIX }}%'
