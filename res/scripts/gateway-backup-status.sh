#!/bin/bash
set -euo pipefail

# Read-only: report the ClickHouse backup destination, its filesystem, the
# configured retention, and the archives on disk (REQ-SECURITY-HARDENING
# FR-4.5/FR-4.6). Mirrors the env contract of res/scripts/gateway-ch-backup.sh.

: "${GW_BACKUP_DIR:?GW_BACKUP_DIR not set (run via make gw-backup-status)}"
: "${GW_BACKUP_KEEP:?GW_BACKUP_KEEP not set (run via make gw-backup-status)}"

echo "backup dir:  ${GW_BACKUP_DIR}"
echo "retention:   keep newest ${GW_BACKUP_KEEP}"

if [ ! -d "$GW_BACKUP_DIR" ]; then
    echo "state:       absent (no backups yet)"
    exit 0
fi

ROOT_SRC="$(findmnt -no SOURCE /)"
DEST_SRC="$(findmnt -no SOURCE --target "$GW_BACKUP_DIR")"
echo "filesystem:  ${DEST_SRC:-?}"
if [ -z "$DEST_SRC" ] || [ "$DEST_SRC" = "$ROOT_SRC" ]; then
    echo "WARNING:     destination is NOT a separate mount (root is ${ROOT_SRC});" >&2
    echo "             the backup job will refuse to run (FR-4.6)." >&2
fi

shopt -s nullglob
ARCHIVES=( "$GW_BACKUP_DIR"/gw-*/ )
shopt -u nullglob
echo "archives:    ${#ARCHIVES[@]}"
if [ "${#ARCHIVES[@]}" -eq 0 ]; then
    exit 0
fi

while IFS= read -r dir; do
    printf '%8s  %s\n' "$(du -sh "$dir" | cut -f1)" "$(basename "$dir")"
done < <(ls -1dt -- "${ARCHIVES[@]}")

printf '%-8s  %s\n' "$(du -sh "$GW_BACKUP_DIR" | cut -f1)" "TOTAL"