#!/bin/bash
set -euo pipefail

# Nightly ClickHouse backup (REQ-SECURITY-HARDENING FR-4.5/FR-4.6, systemd unit
# res/ansible/templates/gateway-ch-backup.{service,timer}.j2). Resolves the
# single destination from GW_BACKUP_DIR, proves it is a distinct writable mount,
# runs the native BACKUP into the container-local `backups` disk, copies the
# archive straight out with `podman cp`, then prunes to the newest
# GW_BACKUP_KEEP. Each step fails the job before an archive can reach the
# encrypted root.
#
# Env (required; from .env via systemd EnvironmentFile):
#   CH_OPS_PASSWORD  ClickHouse ops credential.
#   GW_BACKUP_DIR    destination root (a mount distinct from /).
#   GW_BACKUP_KEEP   max archives retained, newest kept.

CONTAINER="${CLICKHOUSE_CONTAINER:-gw-clickhouse}"
PODMAN="${PODMAN:-${PODMAN_PATH:-podman}}"

fail() { echo "[ch-backup] ERROR: $*" >&2; exit 1; }

: "${CH_OPS_PASSWORD:?CH_OPS_PASSWORD not set (systemd EnvironmentFile=.env)}"
: "${GW_BACKUP_DIR:?GW_BACKUP_DIR not set (systemd EnvironmentFile=.env)}"
: "${GW_BACKUP_KEEP:?GW_BACKUP_KEEP not set (systemd EnvironmentFile=.env)}"
CH_OPS_USER="${CH_OPS_USER:-ops_admin}"

case "$GW_BACKUP_KEEP" in
    ''|*[!0-9]*) fail "GW_BACKUP_KEEP must be a positive integer, got '${GW_BACKUP_KEEP}'" ;;
esac
if [ "$GW_BACKUP_KEEP" -lt 1 ]; then
    fail "GW_BACKUP_KEEP must be >= 1, got ${GW_BACKUP_KEEP}"
fi

_SELF="${BASH_SOURCE[0]}"
case "$_SELF" in
    /proc/*) _SELF="${SHG_SCRIPT_PATH:-$_SELF}" ;;
esac
REPO_ROOT="$(cd "$(dirname "$_SELF")/../.." && pwd)"
# /proc/fd execution (test runners) leaves SHG_SCRIPT_PATH unset; use the
# caller's working directory when it is the repo root.
if [ ! -f "$REPO_ROOT/res/scripts/lib-sql.sh" ] && [ -f "$PWD/res/scripts/lib-sql.sh" ]; then
    REPO_ROOT="$PWD"
fi
export REPO_ROOT
# shellcheck source=/dev/null
source "$REPO_ROOT/res/scripts/lib-sql.sh" || exit 1

DATE="$(date +%F)"
NAME="gw-${DATE}"

chq() {
    printf '%s\n' "$1" | "$PODMAN" exec -i "$CONTAINER" clickhouse-client \
        --user "$CH_OPS_USER" --password "$CH_OPS_PASSWORD" --multiquery
}

# --- 0. Preflight: destination must be a separate, writable mount ---
mkdir -p "$GW_BACKUP_DIR"
ROOT_SRC="$(findmnt -no SOURCE /)"
DEST_SRC="$(findmnt -no SOURCE --target "$GW_BACKUP_DIR")"
if [ -z "$DEST_SRC" ]; then
    fail "cannot resolve the filesystem for GW_BACKUP_DIR=${GW_BACKUP_DIR}"
fi
if [ "$DEST_SRC" = "$ROOT_SRC" ]; then
    fail "GW_BACKUP_DIR=${GW_BACKUP_DIR} is on the root filesystem (${ROOT_SRC}); backups must land on a separate mount"
fi
if ! touch "${GW_BACKUP_DIR}/.gw-write-test"; then
    fail "GW_BACKUP_DIR=${GW_BACKUP_DIR} is not writable by $(id -un)"
fi
rm -f "${GW_BACKUP_DIR}/.gw-write-test"

# --- 1. Create the backup in the container (idempotent) ---
# A failed query (e.g. system.backups empty) means no prior backup; treat as
# empty string. A failed/async leftover is dropped and retried; system.backups
# is a non-persistent view, so removing the directory is the whole cleanup.
STATUS=""
if STATUS_FROM_CH="$(chq "$(sql_render ops/gateway-ch-backup/status.sql NAME="$NAME")")"; then
    STATUS="$STATUS_FROM_CH"
fi
if [ -n "${STATUS:-}" ] && [ "${STATUS:-}" != "BACKUP_CREATED" ]; then
    "$PODMAN" exec "$CONTAINER" rm -rf "/var/lib/clickhouse/backups/${NAME}"
fi
if [ "${STATUS:-}" = "BACKUP_CREATED" ]; then
    echo "[ch-backup] ${NAME} already exists (status BACKUP_CREATED); copy-out only"
else
    echo "[ch-backup] creating ${NAME}"
    chq "$(sql_render ops/gateway-ch-backup/backup.sql NAME="$NAME")"
fi

# --- 2. Copy the finished archive out of the container ---
DEST="${GW_BACKUP_DIR}/${NAME}"
rm -rf "${DEST:?}"
"$PODMAN" cp "${CONTAINER}:/var/lib/clickhouse/backups/${NAME}" "${DEST}"
echo "[ch-backup] wrote ${DEST}"

# --- 3. Retention: keep the newest GW_BACKUP_KEEP archives ---
shopt -s nullglob
ARCHIVES=( "$GW_BACKUP_DIR"/gw-*/ )
shopt -u nullglob
if [ "${#ARCHIVES[@]}" -gt "$GW_BACKUP_KEEP" ]; then
    mapfile -t ORDERED < <(
        find "$GW_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name 'gw-*' \
            -printf '%T@ %p\n' | sort -rn
    )
    i="$GW_BACKUP_KEEP"
    while [ "$i" -lt "${#ORDERED[@]}" ]; do
        OLD="${ORDERED[$i]#* }"
        rm -rf "${OLD:?}"
        echo "[ch-backup] pruned ${OLD}"
        i=$((i + 1))
    done
fi
echo "[ch-backup] done"