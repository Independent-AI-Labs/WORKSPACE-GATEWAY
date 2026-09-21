-- Event ids already present in the target table (lib-opencode-stats-report.sh).
SELECT event_id
FROM {{ DB }}.{{ TABLE }}
WHERE event_id IN ({{ IDS }})
