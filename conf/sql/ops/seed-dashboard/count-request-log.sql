-- seed-clickhouse-dashboard-data.sh: verify seed row count.
SELECT count() FROM {{ DB }}.request_log WHERE request_id LIKE '{{ SEED_RID_PREFIX }}%' FORMAT TabSeparated
