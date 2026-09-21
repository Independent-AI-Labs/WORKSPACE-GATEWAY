-- seed-clickhouse-dashboard-data.sh: drop derived request_signals seed rows.
ALTER TABLE {{ DB }}.request_signals DELETE WHERE model = '{{ SEED_MODEL }}'
