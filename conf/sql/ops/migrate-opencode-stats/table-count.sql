-- Pre-insert backup manifest row count (migrate-opencode-stats.sh).
SELECT count() FROM {{ DB }}.{{ TABLE }}
