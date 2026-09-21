#!/bin/bash
set -euo pipefail

# crunch-usefulness.sh: periodic, idempotent rejection-language cruncher
# (REQ-USEFULNESS-TELEMETRY FR-2). Recomputes request_signals for aligned
# hourly windows from request_log.req_body via the pure-Lua matcher running
# on the APISIX container's luajit (host has no Lua).
#
# Idempotency: per window, DELETE then INSERT; repeated/overlapping runs
# converge (FR-2.2). A flock guards against concurrent runs.
#
# Usage: crunch-usefulness.sh [--dry-run] [--rebuild] [--days N] [--since 'YYYY-MM-DD hh:mm:ss'] [--limit N]
#   --rebuild  DROP + recreate request_signals from the canonical DDL in
#              conf/sql/clickhouse-init.sql, then crunch. For clean recomputes
#              after dictionary/matcher changes; no manual SQL ever.
# Env:  CLICKHOUSE_HOST (default localhost), CLICKHOUSE_PORT (default 8123),
#       PODMAN_BIN (default $PODMAN_PATH or podman), APISIX_CONTAINER,
#       DATABASE (default llm_gateway), FLUSH_WINDOWS (default 12)

CLICKHOUSE_HOST="${CLICKHOUSE_HOST:-localhost}"
CLICKHOUSE_PORT="${CLICKHOUSE_PORT:-8123}"
PODMAN_BIN="${PODMAN_BIN:-${PODMAN_PATH:-podman}}"
APISIX_CONTAINER="${APISIX_CONTAINER:-}"
DATABASE="${DATABASE:-llm_gateway}"
CH_URL="http://${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}"

# Authenticated ops access (REQ-SECURITY-HARDENING FR-1.3): no
# unauthenticated access.
CH_OPS_USER="${CH_OPS_USER:-ops_admin}"
: "${CH_OPS_PASSWORD:?CH_OPS_PASSWORD not set (source repo .env)}"

DRY_RUN=false
REBUILD=false
LIMIT=0
DAYS=1
SINCE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --rebuild) REBUILD=true; shift ;;
    --days) DAYS="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    *) echo "Unknown: $1" >&2; exit 1 ;;
  esac
done

_SELF="${BASH_SOURCE[0]}"
case "$_SELF" in
    /proc/*) _SELF="${SHG_SCRIPT_PATH:-$_SELF}" ;;
esac
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
if [ ! -f "$REPO_ROOT/conf/sql/clickhouse-init.sql" ]; then
    REPO_ROOT="$(pwd)"
fi
if [ ! -f "$REPO_ROOT/conf/sql/clickhouse-init.sql" ]; then
    echo "ERROR: cannot locate repo root (invoked as $_SELF, cwd $(pwd))" >&2
    exit 1
fi
export REPO_ROOT
# shellcheck source=/dev/null
source "$REPO_ROOT/res/scripts/lib-sql.sh" || exit 1

PROF="$REPO_ROOT/conf/profanity/en.txt"
PHRASES="$REPO_ROOT/conf/profanity/frustration-phrases.txt"
VADER="$REPO_ROOT/conf/profanity/vader-negative.txt"
BLOCK="$REPO_ROOT/conf/profanity/fuzzy-blocklist.txt"
CRUNCHER="$REPO_ROOT/res/scripts/usefulness/cruncher.lua"
for f in "$PROF" "$PHRASES" "$VADER" "$BLOCK" "$CRUNCHER"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: missing $f (run make gw-update-dictionaries)" >&2
    exit 1
  fi
done
DICT_VERSION="$(cat "$PROF" "$VADER" "$BLOCK" "$PHRASES" | sha256sum | cut -c1-12)"

CONT_PROF=/etc/apisix/profanity/en.txt
CONT_PHRASES=/etc/apisix/profanity/frustration-phrases.txt
CONT_VADER=/etc/apisix/profanity/vader-negative.txt
CONT_BLOCK=/etc/apisix/profanity/fuzzy-blocklist.txt
CONT_CRUNCHER=/usr/local/apisix/usefulness/cruncher.lua

ch() {
  local sql="$1"
  curl -sSf --max-time 120 --user "$CH_OPS_USER:$CH_OPS_PASSWORD" "$CH_URL/" --data-binary "$sql"
}

# Resolve the apisix container: prefer APISIX_CONTAINER, then the dev compose
# service container (label-filtered, so a stale gw-prod-apisix from the prod
# stack is never picked), then any running container named apisix.
if [ -z "${APISIX_CONTAINER:-}" ]; then
    APSX_RC=0
    APSX_ID=$("$PODMAN_BIN" ps -q \
        --filter label=io.podman.compose.project=docker \
        --filter label=io.podman.compose.service=apisix) || APSX_RC=$?
    if [ "$APSX_RC" -eq 0 ] && [ -n "$APSX_ID" ]; then
        APSX_NAME_RC=0
        APISIX_CONTAINER=$("$PODMAN_BIN" ps --no-trunc --format '{{.Names}}' \
            --filter id="$APSX_ID") || APSX_NAME_RC=$?
        if [ "$APSX_NAME_RC" -ne 0 ] || [ -z "$APISIX_CONTAINER" ]; then
            APISIX_CONTAINER="$APSX_ID"
        fi
    else
        if ! "$PODMAN_BIN" container exists apisix; then
            GREP_RC=0
            APSX_LIST=$("$PODMAN_BIN" ps --format '{{.Names}}') || APSX_LIST=""
            APSX_FOUND=$(printf '%s\n' "$APSX_LIST" | grep -m1 apisix) || GREP_RC=$?
            if [ "$GREP_RC" -eq 0 ]; then
                APISIX_CONTAINER="$APSX_FOUND"
            else
                APISIX_CONTAINER="apisix"
            fi
        else
            APISIX_CONTAINER="apisix"
        fi
    fi
fi

# Bound the last window one hour before now (late inserts excluded by design).
NOW_S=$(( $(date +%s) - 3600 ))
T1=$(( NOW_S - (NOW_S % 3600) ))
if [ -n "$SINCE" ]; then
  T0_S=$(date -u -d "$SINCE" +%s) || { echo "ERROR: bad --since" >&2; exit 1; }
  T0=$(( T0_S - (T0_S % 3600) ))
else
  T0=$(( T1 - DAYS * 86400 ))
  if [ "$T0" -lt $(( T1 - 400 * 86400 )) ]; then
    T0=$(( T1 - 400 * 86400 ))
    echo "[crunch] --days capped to 400 (TTL is 13 months)" >&2
  fi
fi

echo "[crunch] ClickHouse: $CH_URL  db=$DATABASE"
echo "[crunch] windows: $(date -u -d "@$T0" '+%F %T') .. $(date -u -d "@$T1" '+%F %T')  dict_version=$DICT_VERSION  dry_run=$DRY_RUN"
WT0_GLOBAL="$(date -u -d "@$T0" '+%F %T')"
WT1_GLOBAL="$(date -u -d "@$T1" '+%F %T')"

exec 9>/tmp/crunch-usefulness.lock
if ! flock -n 9; then
  echo "[crunch] another run holds the lock; exiting."
  exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if $REBUILD; then
    if $DRY_RUN; then
        echo "[crunch] dry-run: would DROP + recreate ${DATABASE}.request_signals from canonical DDL"
    else
        # Canonical DDL single source of truth: conf/sql/clickhouse-init.sql.
        # Extract the request_signals CREATE block verbatim (up to the first
        # line ending in a semicolon).
        DDL="$(awk '/^CREATE TABLE IF NOT EXISTS llm_gateway\.request_signals \(/,/;$/' \
            "$REPO_ROOT/conf/sql/clickhouse-init.sql")"
        if [ -z "$DDL" ] || ! printf '%s' "$DDL" | grep -q 'ENGINE = ReplacingMergeTree'; then
            echo "[crunch] ERROR: could not extract request_signals DDL from clickhouse-init.sql" >&2
            exit 1
        fi
        ch "$(sql_render ops/crunch-usefulness/drop-request-signals.sql DB="$DATABASE")" \
            || { echo "[crunch] ERROR: rebuild drop failed" >&2; exit 1; }
        ch "$DDL" \
            || { echo "[crunch] ERROR: rebuild create failed" >&2; exit 1; }
        echo "[crunch] request_signals rebuilt from canonical DDL (clickhouse-init.sql)"
    fi
fi

# Hours that actually contain qualifying rows (both the parseable branch and
# the unparseable UNION branch draw from this filter). One prequery instead
# of thousands of empty hourly SELECTs -- the loop below never touches an
# empty window.
HOURS=$(ch "$(sql_render ops/crunch-usefulness/non-empty-hours.sql \
    DB="$DATABASE" WT0="$WT0_GLOBAL" WT1="$WT1_GLOBAL")") \
  || { echo "[crunch] ERROR: hour prequery failed" >&2; exit 1; }
N_HOURS=$(printf '%s\n' "$HOURS" | grep -c . ) || N_HOURS=0
echo "[crunch] $N_HOURS non-empty hourly windows in range"

TOTAL_ROWS=0
TOTAL_SIGNALS=0
N_DONE=0
BATCH_FILE="$TMP_DIR/batch.tsv"
: > "$BATCH_FILE"
BLOCK_START=""
BLOCK_END=""
BLOCK_COUNT=0
BLOCK_ROWS=0
BLOCK_SIG=0
# Windows are committed in blocks of FLUSH_WINDOWS: one DELETE + one INSERT
# per block. One part per hour tripped ClickHouse's inactive-parts guard
# (TOO_MANY_PARTS at 1002); ~12-hour blocks keep part creation ~12x lower
# while block-aligned spans keep runs idempotent (deterministic boundaries).
FLUSH_WINDOWS="${FLUSH_WINDOWS:-12}"

INSERT_SQL="$(sql_render ops/crunch-usefulness/insert-request-signals.sql DB="$DATABASE")"

flush_block() {
  [ "$BLOCK_COUNT" -eq 0 ] && return 0
  if $DRY_RUN; then
    echo "[crunch] ${BLOCK_START} .. ${BLOCK_END}: dry-run windows=$BLOCK_COUNT rows=$BLOCK_ROWS signal_rows=$BLOCK_SIG"
  else
    ch "$(sql_render ops/crunch-usefulness/delete-window.sql \
        DB="$DATABASE" BLOCK_START="$BLOCK_START" BLOCK_END="$BLOCK_END")" \
      || { echo "[crunch] ERROR: block delete failed for ${BLOCK_START}" >&2; exit 1; }
    # curl concatenates multiple --data-binary parts with '&' (form-field
    # semantics), which corrupts the first TSV row of every block insert
    # ("&<request_id>"). Build ONE payload file and send it whole.
    { printf '%s\n' "$INSERT_SQL"; cat "$BATCH_FILE"; } > "$TMP_DIR/insert.payload"
    INSERT_CODE=$(curl -sS --max-time 300 \
        -w '%{http_code}' -o "$TMP_DIR/insert.err" "$CH_URL/" \
        --user "$CH_OPS_USER:$CH_OPS_PASSWORD" \
        --data-binary @"$TMP_DIR/insert.payload") || INSERT_CODE="000"
    if [ "$INSERT_CODE" != "200" ]; then
      echo "[crunch] ERROR: block insert failed for ${BLOCK_START} (HTTP ${INSERT_CODE}):" >&2
      cat "$TMP_DIR/insert.err" >&2
      exit 1
    fi
    echo "[crunch] ${BLOCK_START} .. ${BLOCK_END}: windows=$BLOCK_COUNT rows=$BLOCK_ROWS signal_rows=$BLOCK_SIG committed"
  fi
  TOTAL_ROWS=$(( TOTAL_ROWS + BLOCK_ROWS ))
  TOTAL_SIGNALS=$(( TOTAL_SIGNALS + BLOCK_SIG ))
  : > "$BATCH_FILE"
  BLOCK_START=""
  BLOCK_END=""
  BLOCK_COUNT=0
  BLOCK_ROWS=0
  BLOCK_SIG=0
}

while IFS= read -r WT0; do
  [ -z "$WT0" ] && continue
  W_NEXT_S=$(date -u -d "$WT0" +%s)
  WT1="$(date -u -d "@$((W_NEXT_S + 3600))" '+%F %T')"
  LIMIT_CLAUSE=""
  [[ "$LIMIT" -gt 0 ]] && LIMIT_CLAUSE="LIMIT $LIMIT"

  ROWS=$(ch "$(sql_render ops/crunch-usefulness/fetch-window.sql \
      DB="$DATABASE" WT0="$WT0" WT1="$WT1" LIMIT_CLAUSE="$LIMIT_CLAUSE")") \
      || { echo "[crunch] ERROR: fetch failed for window ${WT0}" >&2; exit 1; }

  N_ROWS=$(printf '%s\n' "$ROWS" | grep -c . ) || N_ROWS=0
  if [ "$N_ROWS" -eq 0 ]; then
    continue
  fi

  MATCHED=$(printf '%s\n' "$ROWS" | "$PODMAN_BIN" exec -i "$APISIX_CONTAINER" \
      /usr/local/openresty/luajit/bin/luajit "$CONT_CRUNCHER" \
      "$CONT_PROF" "$CONT_PHRASES" "$CONT_VADER" "$CONT_BLOCK" "$DICT_VERSION") \
      || { echo "[crunch] ERROR: lua cruncher failed for window ${WT0}" >&2; exit 1; }

  N_SIG=$(printf '%s\n' "$MATCHED" | awk -F'\t' '$12 > 0' | wc -l ) || N_SIG=0

  printf '%s\n' "$MATCHED" >> "$BATCH_FILE"
  if [ -z "$BLOCK_START" ]; then
    BLOCK_START="$WT0"
  fi
  BLOCK_END="$WT1"
  BLOCK_COUNT=$(( BLOCK_COUNT + 1 ))
  BLOCK_ROWS=$(( BLOCK_ROWS + N_ROWS ))
  BLOCK_SIG=$(( BLOCK_SIG + N_SIG ))
  N_DONE=$(( N_DONE + 1 ))

  if [ "$BLOCK_COUNT" -ge "$FLUSH_WINDOWS" ]; then
    flush_block
  fi
done <<< "$HOURS"

flush_block

echo "[crunch] done: windows=$N_DONE/$N_HOURS rows=$TOTAL_ROWS signal_rows=$TOTAL_SIGNALS"
