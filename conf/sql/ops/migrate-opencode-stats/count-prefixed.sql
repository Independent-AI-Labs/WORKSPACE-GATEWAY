-- Count migrated rows by event_id prefix (lib-opencode-stats-report.sh).
SELECT count()
FROM {{ DB }}.{{ TABLE }}
WHERE event_id LIKE '{{ PREFIX }}%'
