-- Pre-insert backup manifest checksum (migrate-opencode-stats.sh).
SELECT sum(cityHash64(*)) FROM {{ DB }}.{{ TABLE }}
