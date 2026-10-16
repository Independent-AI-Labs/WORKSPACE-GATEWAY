#!/bin/bash
set -euo pipefail

# backfill-migrated-ttft.sh - correct ttft_content_ms for rows migrated from
# opencode.db (event_id = ocm_<message_id>).
#
# The migrator's firstpart query excluded reasoning parts, so a reasoning-first
# message was stamped at its first VISIBLE answer text: the decode window
# (duration - ttft) collapsed to the answer tail and inflated tok/s. The
# migrator is fixed for future runs, but re-running it would also re-price
# every migrated row from today's catalog. This tool rewrites ONLY
# ttft_content_ms, sourced from the same sqlite parts the migrator reads, via a
# transient Join-engine lookup and a single mutation.
#
# Usage: res/scripts/backfill-migrated-ttft.sh [--apply] [--database NAME]
#                                              [--opencode-dbs PATH[:PATH...]]
#   --apply           perform the mutation (default: dry-run, print the count)
#   --database NAME   ClickHouse schema (default llm_gateway)
#   --opencode-dbs    colon-separated sqlite sources (default $OPENCODE_DBS)
# Env: CH_OPS_USER (default ops_admin) / CH_OPS_PASSWORD, CLICKHOUSE_HOST/PORT,
#      BATCH_SIZE (default 1000).

CLICKHOUSE_HOST="${CLICKHOUSE_HOST:-localhost}"
CLICKHOUSE_PORT="${CLICKHOUSE_PORT:-8123}"
CH_URL="http://${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}"
DATABASE="llm_gateway"
APPLY=false
BATCH_SIZE="${BATCH_SIZE:-1000}"
OPENCODE_DBS="${OPENCODE_DBS:-$HOME/.local/share/opencode/opencode.db:$HOME/.local/share/opencode/opencode-dev.db}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply) APPLY=true; shift ;;
        --database) DATABASE="$2"; shift 2 ;;
        --opencode-dbs) OPENCODE_DBS="$2"; shift 2 ;;
        *) echo "backfill-migrated-ttft: unknown argument: $1" >&2; exit 1 ;;
    esac
done

CH_OPS_USER="${CH_OPS_USER:-ops_admin}"
: "${CH_OPS_PASSWORD:?CH_OPS_PASSWORD not set (source repo .env)}"

_SELF="${BASH_SOURCE[0]}"
case "$_SELF" in
    /proc/*) _SELF="${SHG_SCRIPT_PATH:-$_SELF}" ;;
esac
REPO_ROOT="$(cd "$(dirname "$_SELF")/../.." && pwd)"
if [ ! -f "$REPO_ROOT/res/scripts/lib-sql.sh" ] && [ -f "$PWD/res/scripts/lib-sql.sh" ]; then
    REPO_ROOT="$PWD"
fi
export REPO_ROOT
# shellcheck source=/dev/null
source "$REPO_ROOT/res/scripts/lib-sql.sh" || exit 1
# shellcheck source=/dev/null
source "$REPO_ROOT/res/scripts/lib-ch.sh" || exit 1

ch() { ch_exec "$1" 600; }

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

echo "[migrated-ttft] ClickHouse: $CH_URL (db=$DATABASE, apply=$APPLY)"

# ---------------------------------------------------------------- extract
: > "$TMPD/ttft.tsv"
IFS=':' read -ra _dbs <<< "$OPENCODE_DBS"
for _src in "${_dbs[@]}"; do
    [ -n "$_src" ] || continue
    if [ ! -f "$_src" ]; then
        echo "[migrated-ttft] source not found, skipping: $_src" >&2
        continue
    fi
    echo "[migrated-ttft] extracting $_src" >&2
    sqlite3 -cmd ".timeout 10000" -batch -separator $'\t' "file:${_src}?mode=ro" \
        "$(sql_render sqlite/opencode-stats/ttft-parts.sql)" >> "$TMPD/ttft.tsv"
done

# Prefix the event id, drop duplicates across sources (first wins), numeric TTFT.
awk -F'\t' -v OFS='\t' '
    $1 != "" && !seen[$1]++ { gsub(/[^A-Za-z0-9_.-]/, "", $1); print "ocm_" $1, ($2 + 0) }
' "$TMPD/ttft.tsv" > "$TMPD/map.tsv"
TOTAL="$(wc -l < "$TMPD/map.tsv")"
echo "[migrated-ttft] mapped messages (with an output part): $TOTAL"
if [ "$TOTAL" = "0" ]; then
    echo "[migrated-ttft] nothing to do."
    exit 0
fi

# ------------------------------------------------------- load lookup table
ch "$(sql_render ops/backfill-migrated-ttft/drop-map.sql DB="$DATABASE")"
ch "$(sql_render ops/backfill-migrated-ttft/create-map.sql DB="$DATABASE")"

n=0
buf=""
while IFS=$'\t' read -r _eid _ttft; do
    [ -n "$_eid" ] || continue
    [ -n "$buf" ] && buf+=","
    buf+="('$_eid',$_ttft)"
    n=$((n + 1))
    if [ $((n % BATCH_SIZE)) -eq 0 ]; then
        ch "$(sql_render ops/backfill-migrated-ttft/insert-map.sql DB="$DATABASE" BUF="$buf")" \
            || { echo "[migrated-ttft] ERROR: batch insert failed at row $n" >&2; exit 1; }
        buf=""
    fi
done < "$TMPD/map.tsv"
if [ -n "$buf" ]; then
    ch "$(sql_render ops/backfill-migrated-ttft/insert-map.sql DB="$DATABASE" BUF="$buf")" \
        || { echo "[migrated-ttft] ERROR: final batch insert failed" >&2; exit 1; }
fi

AFFECTED="$(ch "$(sql_render ops/backfill-migrated-ttft/affected-count.sql DB="$DATABASE")")"
echo "[migrated-ttft] rows to correct: $AFFECTED"

if [ "$AFFECTED" = "0" ] || ! $APPLY; then
    if [ "$AFFECTED" != "0" ]; then
        echo "[migrated-ttft] DRY RUN - no data written. Re-run with --apply."
    else
        echo "[migrated-ttft] nothing to correct."
    fi
    ch "$(sql_render ops/backfill-migrated-ttft/drop-map.sql DB="$DATABASE")"
    exit 0
fi

# --------------------------------------------------------------- apply
echo "[migrated-ttft] applying mutation (mutations_sync=1, this blocks until done)..."
ch "$(sql_render ops/backfill-migrated-ttft/apply-map.sql DB="$DATABASE")"
echo "[migrated-ttft] applied."

echo "[migrated-ttft] verification (remaining / matched):"
ch "$(sql_render ops/backfill-migrated-ttft/verify.sql DB="$DATABASE")"

ch "$(sql_render ops/backfill-migrated-ttft/drop-map.sql DB="$DATABASE")"
echo "[migrated-ttft] done."