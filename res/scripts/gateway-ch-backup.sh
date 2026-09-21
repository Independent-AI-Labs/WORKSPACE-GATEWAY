#!/bin/bash
set -euo pipefail

# Nightly ClickHouse backup (REQ-SECURITY-HARDENING FR-7, systemd unit
# res/systemd/gateway-ch-backup.{service,timer}). Native BACKUP to the
# container-local `backups` disk, copied out to a staging dir, then synced
# to /mnt/ws-backup/workspace-gateway/ when that mount is writable
# (fuseblk, root-owned: the existing root sync job picks it up otherwise -
# see RUNBOOK-SECRETS).
#
# Env (from .env via systemd EnvironmentFile): CH_OPS_PASSWORD.

CONTAINER="${CLICKHOUSE_CONTAINER:-gw-clickhouse}"
PODMAN="${PODMAN:-podman}"
STAGING="${HOME}/.local/state/workspace-gateway/backups"
WS_BACKUP="/mnt/ws-backup/workspace-gateway"
STAGING_KEEP_DAYS=7
BACKUP_KEEP_DAYS=30

fail() { echo "[ch-backup] ERROR: $*" >&2; exit 1; }

: "${CH_OPS_PASSWORD:?CH_OPS_PASSWORD not set (systemd EnvironmentFile=.env)}"
CH_OPS_USER="${CH_OPS_USER:-ops_admin}"

DATE="$(date +%F)"
NAME="gw-${DATE}"

chq() {
    "$PODMAN" exec "$CONTAINER" clickhouse-client \
        --user "$CH_OPS_USER" --password "$CH_OPS_PASSWORD" -q "$1"
}

mkdir -p "$STAGING"

# Idempotency: skip if today's backup already completed. A failed query
# (e.g. system.backups empty) means no prior backup; treat as empty string.
STATUS=""
if STATUS_FROM_CH="$(chq "SELECT status FROM system.backups WHERE name = '${NAME}' ORDER BY start_time DESC LIMIT 1")"; then
    STATUS="$STATUS_FROM_CH"
fi
if [ -n "${STATUS:-}" ] && [ "${STATUS:-}" != "BACKUP_CREATED" ]; then
    # Failed/async leftover of a previous attempt: drop it and retry.
    chq "ALTER TABLE system.backups DELETE WHERE name = '${NAME}'"
    "$PODMAN" exec "$CONTAINER" rm -rf "/var/lib/clickhouse/backups/${NAME}"
fi
if [ "${STATUS:-}" = "BACKUP_CREATED" ]; then
    echo "[ch-backup] ${NAME} already exists (status BACKUP_CREATED); copy-out only"
else
    echo "[ch-backup] creating ${NAME}"
    chq "BACKUP DATABASE llm_gateway TO Disk('backups', '${NAME}')"
fi

# Copy out of the container volume to staging.
rm -rf "${STAGING:?}/${NAME}"
"$PODMAN" cp "${CONTAINER}:/var/lib/clickhouse/backups/${NAME}" "${STAGING}/${NAME}"
echo "[ch-backup] staged ${STAGING}/${NAME}"

# Sync to ws-backup when the mount accepts writes from this user.
if touch "${WS_BACKUP}/.gw-write-test"; then
    rm -f "${WS_BACKUP}/.gw-write-test"
    mkdir -p "$WS_BACKUP"
    rsync -a --delete "${STAGING}/./" "$WS_BACKUP/"
    find "$WS_BACKUP" -mindepth 1 -maxdepth 1 -type d -mtime "+${BACKUP_KEEP_DAYS}" \
        -exec rm -rf {} +
    echo "[ch-backup] synced to ${WS_BACKUP} (retention ${BACKUP_KEEP_DAYS}d)"
else
    echo "[ch-backup] WARN: ${WS_BACKUP} not writable; backup kept in ${STAGING} only" >&2
fi

find "$STAGING" -mindepth 1 -maxdepth 1 -type d -mtime "+${STAGING_KEEP_DAYS}" \
    -exec rm -rf {} +
echo "[ch-backup] done"
