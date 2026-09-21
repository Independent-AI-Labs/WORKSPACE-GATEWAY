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
#              conf/clickhouse-init.sql, then crunch. For clean recomputes
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
if [ ! -f "$REPO_ROOT/conf/clickhouse-init.sql" ]; then
    REPO_ROOT="$(pwd)"
fi
if [ ! -f "$REPO_ROOT/conf/clickhouse-init.sql" ]; then
    echo "ERROR: cannot locate repo root (invoked as $_SELF, cwd $(pwd))" >&2
    exit 1
fi

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
        # Canonical DDL single source of truth: conf/clickhouse-init.sql.
        # Extract the request_signals CREATE block verbatim (up to the first
        # line ending in a semicolon).
        DDL="$(awk '/^CREATE TABLE IF NOT EXISTS llm_gateway\.request_signals \(/,/;$/' \
            "$REPO_ROOT/conf/clickhouse-init.sql")"
        if [ -z "$DDL" ] || ! printf '%s' "$DDL" | grep -q 'ENGINE = ReplacingMergeTree'; then
            echo "[crunch] ERROR: could not extract request_signals DDL from clickhouse-init.sql" >&2
            exit 1
        fi
        ch "DROP TABLE IF EXISTS ${DATABASE}.request_signals" \
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
HOURS=$(ch "SELECT DISTINCT toStartOfHour(timestamp) AS h
FROM ${DATABASE}.request_log
WHERE timestamp >= '${WT0_GLOBAL}' AND timestamp < '${WT1_GLOBAL}'
  AND (uri LIKE '%/chat/completions%' OR uri LIKE '%/responses%')
ORDER BY h FORMAT TabSeparated") \
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

INSERT_SQL="INSERT INTO ${DATABASE}.request_signals
(request_id, model, timestamp, is_followup, parsed, profane, profane_count,
 profane_terms, frustrated, frustration_count, frustration_terms,
 signal_count, signal_weight, guard_blocks, guard_rules, user_rejections,
 rule_denials, dict_version)
FORMAT TabSeparated
"

flush_block() {
  [ "$BLOCK_COUNT" -eq 0 ] && return 0
  if $DRY_RUN; then
    echo "[crunch] ${BLOCK_START} .. ${BLOCK_END}: dry-run windows=$BLOCK_COUNT rows=$BLOCK_ROWS signal_rows=$BLOCK_SIG"
  else
    ch "ALTER TABLE ${DATABASE}.request_signals
        DELETE WHERE timestamp >= '${BLOCK_START}' AND timestamp < '${BLOCK_END}'
        SETTINGS mutations_sync = 2" \
      || { echo "[crunch] ERROR: block delete failed for ${BLOCK_START}" >&2; exit 1; }
    # curl concatenates multiple --data-binary parts with '&' (form-field
    # semantics), which corrupts the first TSV row of every block insert
    # ("&<request_id>"). Build ONE payload file and send it whole.
    { printf '%s' "$INSERT_SQL"; cat "$BATCH_FILE"; } > "$TMP_DIR/insert.payload"
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

  ROWS=$(ch "
SELECT request_id, model, toString(ts) AS ts, if(length(asst) > 0, 1, 0) AS is_followup,
       guard_blocks, guard_rules_csv, user_rejections, rule_denials, last_msg FROM (
    SELECT r.request_id AS request_id, r.model AS model, r.timestamp AS ts,
           countMatches(b.req_body, 'BLOCKED: bash ') + countMatches(b.req_body, 'BLOCKED: ts=') AS guard_blocks,
           arrayStringConcat(extractAll(b.req_body, '[(]([a-z][a-z0-9-]+)[)] [(]2[0-9]{3}-[0-9]{2}-[0-9]{2}T'), ',') AS guard_rules_csv,
           countMatches(b.req_body, 'The user rejected permission to use this specific tool call') AS user_rejections,
           countMatches(b.req_body, 'The user has specified a rule which prevents you from using this specific tool call') AS rule_denials,
           arrayFilter(m -> JSONExtractString(m, 'role') = 'assistant',
               JSONExtractArrayRaw(b.req_body, 'messages')) AS asst,
           arrayFilter(m -> JSONExtractString(m, 'role') = 'user',
               JSONExtractArrayRaw(b.req_body, 'messages')) AS usr,
           if(length(usr) > 0, usr[length(usr)], '') AS last_raw,
           if(last_raw = '', '',
             multiIf(
               JSONType(last_raw, 'content') = 'String',
                 JSONExtractString(last_raw, 'content'),
               JSONType(last_raw, 'content') = 'Array',
                 arrayStringConcat(arrayMap(
                   p -> if(JSONType(p, 'text') = 'String', JSONExtractString(p, 'text'), ''),
                   arrayFilter(p -> JSONHas(p, 'text'),
                     JSONExtractArrayRaw(last_raw, 'content'))), ' '),
               '')) AS last_msg
    FROM ${DATABASE}.request_log AS r
    INNER JOIN ${DATABASE}.request_bodies AS b ON r.event_id = b.event_id
    WHERE r.timestamp >= '${WT0}' AND r.timestamp < '${WT1}'
      AND b.req_body != ''
      AND isValidJSON(b.req_body)
      AND JSONType(b.req_body, 'messages') = 'Array'
      AND (r.uri LIKE '%/chat/completions%' OR r.uri LIKE '%/responses%')
)
UNION ALL
SELECT r.request_id AS request_id, r.model AS model, toString(r.timestamp) AS ts, 0 AS is_followup,
       toUInt16(0) AS guard_blocks, '' AS guard_rules_csv, toUInt16(0) AS user_rejections, toUInt16(0) AS rule_denials, '' AS last_msg
FROM ${DATABASE}.request_log AS r
LEFT JOIN ${DATABASE}.request_bodies AS b ON r.event_id = b.event_id
WHERE r.timestamp >= '${WT0}' AND r.timestamp < '${WT1}'
  AND (r.uri LIKE '%/chat/completions%' OR r.uri LIKE '%/responses%')
  AND (b.event_id = '' OR b.req_body = '' OR NOT isValidJSON(b.req_body)
       OR JSONType(b.req_body, 'messages') != 'Array')
${LIMIT_CLAUSE}
FORMAT TabSeparated") || { echo "[crunch] ERROR: fetch failed for window ${WT0}" >&2; exit 1; }

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
