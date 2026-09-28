#!/bin/bash
set -euo pipefail

# reconcile-model-attribution.sh: idempotent reconciliation of model identity
# across llm_gateway.request_log, usage_log and billing_ledger.
#
# Background: until 2026-09-27 the sse-usage plugin never published
# $sse_model/$sse_stream, so any request whose logged body was 256 KiB-cap
# truncated lost request_log.model. Separately, older rows carry garbage
# model_raw (probe markers) or a stale canonical id (e.g. k3 -> kimi-k2.7-code
# where the registry says kimi-k3). The single source of truth is
# conf/model-registry.yaml; this tool re-derives {model, model_raw} from it,
# cross-checking usage_log/request_log/billing_ledger against each other.
#
# Safety model:
#   * DRY RUN BY DEFAULT. Nothing is swapped without --apply. The dry run
#     still builds all three shadow copies, verifies row counts and drops
#     them, so the SQL and the no-loss guarantee are proven first.
#   * Every shadow copy is row-count verified against its source BEFORE the
#     EXCHANGE; a mismatch aborts and the source table is never swapped.
#   * billing_ledger_mv is dropped before its source/target are swapped and is
#     restored from mv-create.sql on exit, success or failure.
#   * Only empty/garbage/inconsistent values are changed; a re-run converges.
#
# Usage: reconcile-model-attribution.sh [--apply | --check] [--database llm_gateway]
#   --check  read-only: exit nonzero if any table still disagrees with its
#            authoritative sibling (for the scheduled guard / CI).
# Env: CH_OPS_USER/CH_OPS_PASSWORD (required), CLICKHOUSE_HOST/PORT, DATABASE.

_SELF="${BASH_SOURCE[0]}"
case "$_SELF" in
    /proc/*) _SELF="${SHG_SCRIPT_PATH:-$_SELF}" ;;
esac
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
if [ ! -f "$REPO_ROOT/conf/sql/clickhouse-init.sql" ]; then
    REPO_ROOT="$(pwd)"
fi
export REPO_ROOT
# shellcheck source=/dev/null
source "$REPO_ROOT/res/scripts/lib-sql.sh" || exit 1
# shellcheck source=../../tests/config/yaml_helpers.sh
source "$REPO_ROOT/tests/config/yaml_helpers.sh" || exit 1

CLICKHOUSE_HOST="${CLICKHOUSE_HOST:-localhost}"
CLICKHOUSE_PORT="${CLICKHOUSE_PORT:-8123}"
CH_URL="http://${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}"
DB="${DATABASE:-llm_gateway}"
REGISTRY="$REPO_ROOT/conf/model-registry.yaml"
OPS="ops/reconcile-model-attribution"

: "${CH_OPS_PASSWORD:?CH_OPS_PASSWORD not set (source repo .env)}"
CH_OPS_USER="${CH_OPS_USER:-ops_admin}"

APPLY=false
CHECK=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=true; shift ;;
    --check) CHECK=true; shift ;;
    --database) DB="$2"; shift 2 ;;
    *) echo "Unknown: $1" >&2; exit 2 ;;
  esac
done
if $APPLY && $CHECK; then
  echo "[backfill] ERROR: --apply and --check are mutually exclusive" >&2
  exit 2
fi

ch() {
  local sql="$1"
  curl -sS --fail-with-body --max-time 300 --user "$CH_OPS_USER:$CH_OPS_PASSWORD" "$CH_URL/" --data-binary "$sql"
}

ch_value() {
  local out query_status first_line
  out=$(ch "$1 FORMAT TabSeparated")
  query_status=$?
  if [ "$query_status" -ne 0 ]; then
    echo "[backfill] ERROR: ClickHouse query failed (status=$query_status)" >&2
    return 1
  fi
  read -r first_line <<< "$out"
  echo "$first_line"
}

# Read-only drift guard: exit nonzero if any table still disagrees with its
# authoritative sibling, so an attribution regression fails loudly
# instead of quietly shrinking the score's denominators.
if $CHECK; then
  echo "[backfill] ClickHouse: $CH_URL database=$DB check"
  CHECK_OUT=$(ch "$(sql_render "$OPS/drift-check.sql" DB="$DB")") \
    || { echo "[backfill] ERROR: drift-check query failed" >&2; exit 2; }
  printf '%s\n' "$CHECK_OUT"
  total=$(printf '%s\n' "$CHECK_OUT" \
    | awk -F'\t' 'NR == 1 { next } { for (i = 1; i <= NF; i++) s += $i } END { print s + 0 }')
  if [ "${total:-0}" -eq 0 ]; then
    echo "[backfill] OK: no model-attribution drift"
    exit 0
  fi
  echo "[backfill] DRIFT: ${total} attributable mismatch(es); run: make gw-reconcile-model-attribution APPLY=1" >&2
  exit 1
fi

# Build the registry canonicalization expression used by every insert.
# {{ CANON_EXPR }} maps lower(local_raw) exactly, else its last '/'-segment,
# else the segment itself - the same algorithm as model_registry.lua / VRL.
# The alias pairs come from conf/model-registry.yaml via the same
# yaml_to_json + jq path as res/scripts/gen-model-registry.sh (one source,
# one parse), not a hand-rolled parser.
build_canon_expr() {
  local json pairs
  json="$(yaml_to_json "$REGISTRY")"
  if [ -z "$json" ]; then
    echo "[backfill] ERROR: could not parse $REGISTRY" >&2
    return 1
  fi
  pairs="$(printf '%s' "$json" | jq -r '
    .models | to_entries[] | .key as $c
    | ([$c] + [(.value.aliases // [])[] | ascii_downcase])[]
    | [., $c] | @tsv')"
  if [ -z "$pairs" ]; then
    echo "[backfill] ERROR: registry produced no alias pairs" >&2
    return 1
  fi
  local map_args="" a c
  while IFS=$'\t' read -r a c; do
    [ -n "$a" ] || continue
    map_args+="'$a', '$c', "
  done <<< "$pairs"
  local map="map(${map_args%, })"
  local seg="splitByChar('/', lower(local_raw))[length(splitByChar('/', lower(local_raw)))]"
  CANON_EXPR="if(${map}[lower(local_raw)] != '', ${map}[lower(local_raw)], if(${map}[${seg}] != '', ${map}[${seg}], ${seg}))"
}

build_canon_expr
echo "[backfill] ClickHouse: $CH_URL database=$DB apply=$APPLY"
echo "[backfill] Registry: $(wc -l < "$REGISTRY") lines -> canonical expr ${#CANON_EXPR} bytes"

echo ""
echo "[backfill] BEFORE:"
ch "$(sql_render "$OPS/before-snapshot.sql" DB="$DB")"

# ---- build + verify all three shadow copies (non-destructive) ----
build_shadow() {
  local table="$1" insert_sql="$2"
  local before shadow
  before=$(ch_value "$(sql_render "$OPS/row-count.sql" DB="$DB" TABLE="$table")")
  echo "[backfill] $table: building shadow (source rows=$before)..."
  ch "$(sql_render "$OPS/drop-backfill.sql" DB="$DB" TABLE="$table")"
  ch "$(sql_render "$OPS/create-backfill.sql" DB="$DB" TABLE="$table")"
  ch "$(sql_render "$insert_sql" DB="$DB" CANON_EXPR="$CANON_EXPR")"
  shadow=$(ch_value "$(sql_render "$OPS/shadow-count.sql" DB="$DB" TABLE="$table")")
  if [ "$shadow" != "$before" ]; then
    echo "[backfill] FAIL: $table shadow rows ($shadow) != source rows ($before); nothing swapped" >&2
    exit 1
  fi
  echo "[backfill] $table: shadow verified ($shadow rows)"
}

if ! $APPLY; then
  build_shadow request_log "$OPS/insert-request-log.sql"
  build_shadow usage_log "$OPS/insert-usage-log.sql"
  build_shadow billing_ledger "$OPS/insert-billing-ledger.sql"
  echo ""
  echo "[backfill] Shadow post-state (what the swap would produce):"
  ch "$(sql_render "$OPS/shadow-report.sql" DB="$DB")"
  echo ""
  echo "[backfill] Previously-broken request_log raws in the shadow:"
  ch "$(sql_render "$OPS/shadow-sample.sql" DB="$DB")"
  echo ""
  echo "[backfill] DRY RUN -- shadows verified; dropping them, sources untouched."
  for t in request_log usage_log billing_ledger; do
    ch "$(sql_render "$OPS/drop-backfill.sql" DB="$DB" TABLE="$t")"
  done
  echo "[backfill] Re-run with --apply to swap."
  exit 0
fi

# ---- drop billing_ledger_mv before swapping its source/target ----
# Its definition is replayed from mv-create.sql, NOT from
# system.tables.create_table_query (the stored SELECT body backslash-escapes
# every quote, so replaying it verbatim is a syntax error).
MV_DDL="$(sql_render "$OPS/mv-create.sql" DB="$DB")"
MV_RESTORED=0
restore_mv() {
  if [ -n "$MV_DDL" ] && [ "$MV_RESTORED" != "1" ]; then
    echo "[backfill] restoring billing_ledger_mv..." >&2
    if ch "$MV_DDL"; then MV_RESTORED=1; else
      echo "[backfill] ERROR: MV restore failed; re-run migrations/provision" >&2
    fi
  fi
}
trap restore_mv EXIT

echo ""
echo "[backfill] Dropping billing_ledger_mv (definition in mv-create.sql, will be restored)..."
ch "$(sql_render "$OPS/mv-drop.sql" DB="$DB")"

swap() {
  local table="$1"
  local now shadow
  now=$(ch_value "$(sql_render "$OPS/row-count.sql" DB="$DB" TABLE="$table")")
  shadow=$(ch_value "$(sql_render "$OPS/shadow-count.sql" DB="$DB" TABLE="$table")")
  if [ "$now" != "$shadow" ]; then
    echo "[backfill] FAIL: $table changed under us (source=$now shadow=$shadow); re-run" >&2
    exit 1
  fi
  echo "[backfill] $table: swapping ($now rows)..."
  ch "$(sql_render "$OPS/exchange-backfill.sql" DB="$DB" TABLE="$table")"
  ch "$(sql_render "$OPS/drop-backfill-final.sql" DB="$DB" TABLE="$table")"
}

# Build + swap one table at a time so a dependent table (billing_ledger reads
# the corrected usage_log by event_id) is reconciled against the new state.
build_shadow request_log "$OPS/insert-request-log.sql"
swap request_log
build_shadow usage_log "$OPS/insert-usage-log.sql"
swap usage_log
build_shadow billing_ledger "$OPS/insert-billing-ledger.sql"
swap billing_ledger

echo "[backfill] Restoring billing_ledger_mv..."
ch "$MV_DDL"
MV_RESTORED=1

echo ""
echo "[backfill] AFTER:"
ch "$(sql_render "$OPS/after-snapshot.sql" DB="$DB")"

REMAINING=$(ch_value "$(sql_render "$OPS/remaining-count.sql" DB="$DB")")
REMAINING=${REMAINING:-0}
echo ""
echo "[backfill] Rows still model-less (unrecoverable: pre-request-id 2026-07 traffic): $REMAINING"
echo "[backfill] Done."
