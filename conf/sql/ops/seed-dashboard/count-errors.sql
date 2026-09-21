-- seed-clickhouse-dashboard-data.sh: verify the seed has 4xx/5xx rows.
SELECT countIf(status >= 400) FROM {{ DB }}.request_log WHERE request_id LIKE '{{ SEED_RID_PREFIX }}%' FORMAT TabSeparated
