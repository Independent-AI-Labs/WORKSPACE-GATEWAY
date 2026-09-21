-- Latest backup status for {{ NAME }} (res/scripts/gateway-ch-backup.sh).
SELECT status
FROM system.backups
WHERE position(name, '{{ NAME }}') > 0
ORDER BY start_time DESC
LIMIT 1
