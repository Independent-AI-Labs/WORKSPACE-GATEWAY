#!/bin/bash
set -euo pipefail

# recalc-costs.sh: idempotent, non-destructive cost recalculation over
# llm_gateway.usage_log (SPEC-COST-CALC section 6). The math lives in
# res/scripts/cost/recalc.lua and reuses cost_calc.compute_cost, so a repair
# pass and the live request path share exactly one formula.
#
# Safety model:
#   * DRY RUN BY DEFAULT. Nothing is written without --apply.
#   * SMALL BATCH BY DEFAULT (--limit 100). Widen only once the dry run and a
#     small applied batch look right. --all additionally needs --confirm-all.
#   * upstream rows are revalued like any other: billed cost is always the
#     provider-scoped price, never the upstream-reported cost (which lives
#     in the separate reported_cost column and is never rewritten).
#   * On --apply a FULL llm_gateway backup is taken first and its status
#     verified; abort if it fails or --no-backup is not explicitly passed.
#   * a provider is resolved only through the explicit route/alias map in
#     cost_calc (cost_calc.resolve_provider), with no other provider;
#   * Every old->new pair is written to cost_recalc_audit before the row is
#     mutated; no row is ever deleted.
#   * Re-running converges: only rows whose cost still differs are emitted.
#
# Usage:
#   recalc-costs.sh [--apply] [--limit N|--all [--confirm-all]]
#                   [--days N | --since 'YYYY-MM-DD hh:mm:ss']
#                   [--source unknown,provider_override,models_dev] [--epsilon 1e-9]
#                   [--database llm_gateway] [--no-backup]
#
# Env: CH_OPS_USER/CH_OPS_PASSWORD (required), CLICKHOUSE_HOST/PORT,
#      GATEWAY_URL, PODMAN_BIN/PODMAN, APISIX_CONTAINER.

_SELF="${BASH_SOURCE[0]}"
case "$_SELF" in
    /proc/*) _SELF="${SHG_SCRIPT_PATH:-$_SELF}" ;;
esac
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
if [ ! -f "$REPO_ROOT/conf/clickhouse-init.sql" ]; then
    REPO_ROOT="$(pwd)"
fi

CLICKHOUSE_HOST="${CLICKHOUSE_HOST:-localhost}"
CLICKHOUSE_PORT="${CLICKHOUSE_PORT:-8123}"
CH_URL="http://${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}"
PODMAN_BIN="${PODMAN_BIN:-${PODMAN_PATH:-podman}}"
APISIX_CONTAINER="${APISIX_CONTAINER:-}"
GATEWAY_URL="${GATEWAY_URL:-http://127.0.0.1:9080}"
DB="${DATABASE:-llm_gateway}"
RECALC_LUA="$REPO_ROOT/res/scripts/cost/recalc.lua"
COST_CALC="$REPO_ROOT/plugins/custom/cost_calc.lua"
MODEL_REGISTRY="$REPO_ROOT/plugins/custom/model_registry.lua"
CONT_PLUGINS=/usr/local/apisix/apisix/plugins

: "${CH_OPS_PASSWORD:?CH_OPS_PASSWORD not set (source repo .env)}"
CH_OPS_USER="${CH_OPS_USER:-ops_admin}"

APPLY=false
LIMIT=100
CONFIRM_ALL=false
DAYS=0
SINCE=""
SOURCES="unknown,provider_override,models_dev"
EPSILON="1e-9"
DO_BACKUP=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=true; shift ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --all) LIMIT=0; shift ;;
    --confirm-all) CONFIRM_ALL=true; shift ;;
    --days) DAYS="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    --source) SOURCES="$2"; shift 2 ;;
    --epsilon) EPSILON="$2"; shift 2 ;;
    --database) DB="$2"; shift 2 ;;
    --no-backup) DO_BACKUP=false; shift ;;
    *) echo "Unknown: $1" >&2; exit 2 ;;
  esac
done

if [[ "$LIMIT" -eq 0 && "$APPLY" == true && "$CONFIRM_ALL" != true ]]; then
  echo "[recalc] REFUSING --apply --all without --confirm-all (run a small batch first)" >&2
  exit 1
fi

ch() {
  curl -sSf --max-time 300 --user "$CH_OPS_USER:$CH_OPS_PASSWORD" "$CH_URL/" --data-binary "$1"
}
ch_long() {
  curl -sSf --max-time 1800 --user "$CH_OPS_USER:$CH_OPS_PASSWORD" "$CH_URL/" --data-binary "$1"
}
# ch_payload sends a file that carries its own full statement (used for
# INSERT ... FORMAT: header + TSV data in one body, as ClickHouse expects).
ch_payload() {
  curl -sSf --max-time 900 --user "$CH_OPS_USER:$CH_OPS_PASSWORD" "$CH_URL/" --data-binary @"$1"
}
# ch_value reads a single scalar; empty/err yields "".
ch_value() {
  local out
  out="$(ch "$1")" || return 1
  printf '%s' "${out%%$'\n'*}"
}
esc() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\'/\\\'}"
  echo "'$s'"
}

for f in "$RECALC_LUA" "$COST_CALC" "$MODEL_REGISTRY"; do
  [ -f "$f" ] || { echo "[recalc] ERROR: missing $f" >&2; exit 1; }
done

# Resolve the apisix container (same resolution as crunch-usefulness.sh).
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
        if "$PODMAN_BIN" container exists apisix; then
            APISIX_CONTAINER="apisix"
        else
            APISIX_CONTAINER=""
            while IFS= read -r name; do
                case "$name" in *apisix*) APISIX_CONTAINER="$name"; break ;; esac
            done < <("$PODMAN_BIN" ps --format '{{.Names}}')
            [ -n "$APISIX_CONTAINER" ] || APISIX_CONTAINER="apisix"
        fi
    fi
fi

RUN_ID="run-$(date -u +%Y%m%d%H%M%S)-$$"
echo "[recalc] db=$DB ch=$CH_URL apply=$APPLY limit=$LIMIT source=$SOURCES run_id=$RUN_ID"

# ---- 1. provider-scoped rates from the live gateway catalog ----
echo "[recalc] Fetching gateway catalog pricing..."
PROVIDER_LIST_JSON=$(curl -sSf --max-time 30 "${GATEWAY_URL}/gateway/providers") || {
  echo "[recalc] ERROR: failed to fetch ${GATEWAY_URL}/gateway/providers" >&2
  exit 1
}
CATALOG_JSON="[]"
while read -r pid; do
  [ -z "$pid" ] && continue
  DETAIL=$(curl -sSf --max-time 30 "${GATEWAY_URL}/gateway/providers/${pid}") || {
    echo "[recalc] ERROR: failed to fetch provider ${pid}" >&2
    exit 1
  }
  CATALOG_JSON=$(jq -c --argjson d "$DETAIL" '. + [$d]' <<< "$CATALOG_JSON")
done < <(jq -r '.[].id' <<< "$PROVIDER_LIST_JSON")

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
RATES="$TMP_DIR/rates.tsv"
jq -r '
  [ .[] | .id as $p | (.models // {}) | to_entries[]
    | select(.value.cost != null)
    | [ $p, .key,
        (.value.cost.input // 0), (.value.cost.output // 0),
        (.value.cost.cache_read // 0), (.value.cost.cache_write // 0),
        (.value.cost.reasoning // 0),
        (.value.pricing.source) ] ]
  | sort_by(.[0], .[1])[]
  | @tsv
' <<< "$CATALOG_JSON" > "$RATES"

RATE_ROWS=$(grep -c . "$RATES") || RATE_ROWS=0
if [ "$RATE_ROWS" -eq 0 ]; then
  echo "[recalc] ERROR: catalog yielded no priced models; aborting (no data written)" >&2
  exit 1
fi
echo "[recalc] rates rows: $RATE_ROWS"

# ---- 2. usage rows to reconcile ----
SOURCE_SQL=""
for s in ${SOURCES//,/ }; do
  [ -n "$s" ] || continue
  SOURCE_SQL="${SOURCE_SQL:+$SOURCE_SQL,}$(esc "$s")"
done
if [ -z "$SOURCE_SQL" ]; then
  echo "[recalc] ERROR: --source produced an empty list" >&2
  exit 2
fi
WHERE="cost_source IN ($SOURCE_SQL)"
if [ -n "$SINCE" ]; then
  WHERE="$WHERE AND timestamp >= toDateTime64($(esc "$SINCE"), 3)"
elif [ "$DAYS" -gt 0 ]; then
  WHERE="$WHERE AND timestamp >= now() - INTERVAL $DAYS DAY"
fi
LIMIT_CLAUSE=""
[ "$LIMIT" -gt 0 ] && LIMIT_CLAUSE="LIMIT $LIMIT"

ROWS="$TMP_DIR/rows.tsv"
ch "SELECT event_id, request_id, toString(timestamp), provider_id, model,
           prompt_tokens, completion_tokens, total_tokens, cached_tokens,
           cache_write_tokens, reasoning_tokens, toString(cost_source), cost
    FROM ${DB}.usage_log
    WHERE $WHERE
    ORDER BY timestamp
    $LIMIT_CLAUSE
    FORMAT TabSeparated" > "$ROWS"

ROW_COUNT=$(grep -c . "$ROWS") || ROW_COUNT=0
echo "[recalc] candidate rows: $ROW_COUNT"
if [ "$ROW_COUNT" -eq 0 ]; then
  echo "[recalc] nothing to do."
  exit 0
fi

# ---- 3. recompute via Lua (one shared formula) ----
"$PODMAN_BIN" cp "$RECALC_LUA" "$APISIX_CONTAINER:/tmp/recalc.lua"
"$PODMAN_BIN" cp "$COST_CALC" "$APISIX_CONTAINER:/tmp/cost_calc.lua"
"$PODMAN_BIN" cp "$MODEL_REGISTRY" "$APISIX_CONTAINER:/tmp/model_registry.lua"
"$PODMAN_BIN" cp "$RATES" "$APISIX_CONTAINER:/tmp/recalc_rates.tsv"

CORRECTIONS="$TMP_DIR/corrections.tsv"
"$PODMAN_BIN" exec -i "$APISIX_CONTAINER" \
  env LUA_PATH="/tmp/?.lua;/usr/local/apisix/?.lua;${CONT_PLUGINS}/?.lua;;" \
  /usr/local/openresty/luajit/bin/luajit /tmp/recalc.lua /tmp/recalc_rates.tsv "$EPSILON" \
  < "$ROWS" > "$CORRECTIONS"

FIX_COUNT=$(grep -c . "$CORRECTIONS") || FIX_COUNT=0
echo "[recalc] rows needing correction: $FIX_COUNT"
if [ "$FIX_COUNT" -eq 0 ]; then
  echo "[recalc] already reconciled (idempotent no-op)."
  if [ "$APPLY" = true ]; then
    echo "[recalc] applied=0 failed=0 (provider groups=0 cost groups=0) run_id=$RUN_ID"
  fi
  exit 0
fi

echo "[recalc] sample (event_id  new  old  source  provider  old_provider):"
SAMPLE_N=0
while IFS=$'\x1f' read -r eid _rid _ts new old src pid _m oldpid _canon _pi _po _pcr _pcw _prr _nsrc; do
  [ -n "$eid" ] || continue
  echo "  $eid  new=$new old=$old source=$src provider=${pid:-$oldpid} (was ${oldpid:-none})"
  SAMPLE_N=$((SAMPLE_N + 1))
  [ "$SAMPLE_N" -ge 5 ] && break
done < "$CORRECTIONS"

if [ "$APPLY" != true ]; then
  echo "[recalc] DRY RUN -- no backup taken, nothing written. Re-run with --apply (keep --limit small)."
  exit 0
fi

# ---- 4. full pre-change backup (mandatory unless --no-backup) ----
if [ "$DO_BACKUP" = true ]; then
  BNAME="pre-recalc-${RUN_ID#run-}"
  echo "[recalc] BACKUP DATABASE ${DB} TO Disk('backups','${BNAME}') ..."
  if ! BACKUP_OUT=$(ch_long "BACKUP DATABASE ${DB} TO Disk('backups', '${BNAME}')"); then
    echo "[recalc] ERROR: BACKUP statement failed; aborting before any write" >&2
    printf '%s\n' "$BACKUP_OUT" >&2
    exit 1
  fi
  # system.backups.name is the full spec Disk('backups', '<name>'), so match
  # by substring rather than equality on the bare name.
  BSTATUS=$(ch_value "SELECT status FROM system.backups WHERE position(name, '${BNAME}') > 0 ORDER BY start_time DESC LIMIT 1") || BSTATUS=""
  if [ "$BSTATUS" != "BACKUP_CREATED" ]; then
    echo "[recalc] ERROR: backup '${BNAME}' status='${BSTATUS}' (not BACKUP_CREATED); aborting" >&2
    exit 1
  fi
  echo "[recalc] backup verified: ${BNAME}"
else
  echo "[recalc] WARN: --no-backup set; proceeding without a fresh backup" >&2
fi

# ---- 5. audit table + append old->new before mutating ----
ch "CREATE TABLE IF NOT EXISTS ${DB}.cost_recalc_audit (
      event_id String,
      provider_id LowCardinality(String) DEFAULT '',
      new_provider_id LowCardinality(String) DEFAULT '',
      model LowCardinality(String) DEFAULT '',
      old_cost Float64,
      new_cost Float64,
      old_source LowCardinality(String) DEFAULT '',
      run_id String,
      timestamp DateTime64(3) DEFAULT now()
    )
    ENGINE = MergeTree()
    PARTITION BY toYYYYMM(timestamp)
    ORDER BY (event_id, run_id, timestamp)
    TTL toDateTime(timestamp) + INTERVAL 13 MONTH"
# Existing audit tables predate the provider-backfill column.
ch "ALTER TABLE ${DB}.cost_recalc_audit
    ADD COLUMN IF NOT EXISTS new_provider_id LowCardinality(String) DEFAULT ''"

echo "[recalc] writing audit rows..."
{
  while IFS=$'\x1f' read -r eid _rid _ts new old src pid model oldpid _canon _pi _po _pcr _pcw _prr _nsrc; do
    [ -z "$eid" ] && continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$eid" "$oldpid" "$pid" "$model" "$old" "$new" "$src" "$RUN_ID"
  done < "$CORRECTIONS"
} > "$TMP_DIR/audit.tsv"

{
  printf 'INSERT INTO %s.cost_recalc_audit\n' "$DB"
  printf '    (event_id, provider_id, new_provider_id, model, old_cost, new_cost, old_source, run_id)\n'
  printf '    FORMAT TabSeparated\n'
  cat "$TMP_DIR/audit.tsv"
} > "$TMP_DIR/audit.payload"
ch_payload "$TMP_DIR/audit.payload"

# ---- 6. apply in bulk (one UPDATE per mapping / rate group) ----
# ClickHouse mutations re-encode whole parts, so the cost of a pass is the
# number of ALTER statements, not the number of rows. Corrections are
# therefore collapsed into: one provider_id UPDATE per (old -> new, route)
# mapping, and one cost UPDATE per distinct (provider, rate) tuple. A
# full-table repair is tens of statements, not tens of thousands.
echo "[recalc] applying corrections in bulk..."
APPLIED=0
FAILED=0

declare -A PG=()        # provider group key -> WHERE predicate
declare -A COST_MODELS=()  # rate-group key -> "model","model",...
declare -A COST_SEEN=()    # rate-group key + model -> 1

while IFS=$'\x1f' read -r eid _rid _ts new old src pid model oldpid canonical pi po pcr pcw prr nsrc; do
  [ -z "$eid" ] && continue

  if [ "$pid" != "$oldpid" ]; then
    if [ -z "$oldpid" ]; then
      route="${eid%_*}"
      PG["route|$route|$pid"]="provider_id = '' AND match(event_id, '^${route}_[0-9]+\$')"
    else
      PG["alias|$oldpid|$pid"]="provider_id = $(esc "$oldpid")"
    fi
  fi

  if [ "$new" != "$old" ] || [ "$src" != "$nsrc" ]; then
    gkey="$pid|$canonical|$pi|$po|$pcr|$pcw|$prr|$nsrc"
    mkey="$gkey|$model"
    if [ -z "${COST_SEEN[$mkey]:-}" ]; then
      COST_SEEN[$mkey]=1
      COST_MODELS[$gkey]="${COST_MODELS[$gkey]:-}${COST_MODELS[$gkey]:+,}$(esc "$model")"
    fi
  fi
done < "$CORRECTIONS"

# ---- 6a. provider_id backfill (canonicalize aliases / recover from route) ----
if [ "${#PG[@]}" -gt 0 ]; then
  for k in "${!PG[@]}"; do
    new_pid="${k##*|}"
    if ALTER_OUT=$(ch "ALTER TABLE ${DB}.usage_log
           UPDATE provider_id = $(esc "$new_pid")
           WHERE ${PG[$k]}
             AND provider_id != $(esc "$new_pid")
             AND cost_source IN ($SOURCE_SQL)
           SETTINGS mutations_sync = 1"); then
      APPLIED=$((APPLIED + 1))
    else
      FAILED=$((FAILED + 1))
      echo "[recalc] ERROR: provider backfill failed for ${k}" >&2
      printf '%s\n' "$ALTER_OUT" >&2
    fi
  done
fi

# ---- 6b. cost revalue, one UPDATE per (provider, rate) tuple ----
# The expression is the same arithmetic cost_calc.compute_cost performs in
# Lua (input_uncached clamped at 0, reasoning treated as a subset of
# completion unless it exceeds it). Re-running converges because the
# abs(cost - expr) > epsilon guard skips already-correct rows.
if [ "${#COST_MODELS[@]}" -gt 0 ]; then
  for gkey in "${!COST_MODELS[@]}"; do
    IFS='|' read -r cpid _ccanon pi po pcr pcw prr nsrc <<< "$gkey"
    EXPR="greatest(toInt64(prompt_tokens) - toInt64(cached_tokens) - toInt64(cache_write_tokens), 0) * $pi / 1e6
          + if(toInt64(completion_tokens) - toInt64(reasoning_tokens) >= 0, toInt64(completion_tokens) - toInt64(reasoning_tokens), toInt64(completion_tokens)) * $po / 1e6
          + toInt64(cached_tokens) * $pcr / 1e6
          + toInt64(cache_write_tokens) * $pcw / 1e6
          + toInt64(reasoning_tokens) * $prr / 1e6"
    if ALTER_OUT=$(ch "ALTER TABLE ${DB}.usage_log
           UPDATE cost = $EXPR, cost_source = $(esc "$nsrc")
           WHERE provider_id = $(esc "$cpid")
             AND model IN (${COST_MODELS[$gkey]})
             AND cost_source IN ($SOURCE_SQL)
             AND (abs(cost - ($EXPR)) > $EPSILON OR cost_source != $(esc "$nsrc"))
           SETTINGS mutations_sync = 1"); then
      APPLIED=$((APPLIED + 1))
    else
      FAILED=$((FAILED + 1))
      echo "[recalc] ERROR: cost revalue failed for provider=${cpid}" >&2
      printf '%s\n' "$ALTER_OUT" >&2
    fi
  done
fi

echo "[recalc] applied=$APPLIED failed=$FAILED (provider groups=${#PG[@]} cost groups=${#COST_MODELS[@]}) run_id=$RUN_ID"
[ "$FAILED" -eq 0 ] || exit 1
echo "[recalc] done. Audit: SELECT * FROM ${DB}.cost_recalc_audit WHERE run_id = '${RUN_ID}'"
