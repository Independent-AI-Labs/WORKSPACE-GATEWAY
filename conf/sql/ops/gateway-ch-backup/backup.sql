-- Nightly ClickHouse backup (res/scripts/gateway-ch-backup.sh).
BACKUP DATABASE {{ DB }} TO Disk('backups', '{{ NAME }}')
