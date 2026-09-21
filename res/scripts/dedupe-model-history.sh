#!/bin/bash
set -euo pipefail

# dedupe-model-history.sh
# One-off historical merge: rewrite every alias-shaped model string in
# ClickHouse to its canonical id from conf/model-registry.yaml. Cost repair
# is owned by res/scripts/recalc-costs.sh (provider-scoped, audit-backed).
#
#   usage_log:      ALTER UPDATE in place (model not in ORDER BY).
#                   model_raw is set to the pre-merge value for audit.
#   billing_ledger: same, on model_name.
#   request_log:    model IS in the ORDER BY key, so ClickHouse refuses
#                   ALTER UPDATE; a shadow-table swap is done instead.
#
# Usage:
#   ./dedupe-model-history.sh [--dry-run]
#
# Depends: curl, jq, podman (for YAML parse via tests/config/yaml_helpers.sh)

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
    _SELF="$SHG_SCRIPT_PATH"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CLICKHOUSE_HOST="${CLICKHOUSE_HOST:-localhost}"
CLICKHOUSE_PORT="${CLICKHOUSE_PORT:-8123}"
CH_URL="http://${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}"
DB="${DATABASE:-llm_gateway}"
DRY_RUN=false

# Authenticated ops access (REQ-SECURITY-HARDENING FR-1.3): no
# unauthenticated access.
CH_OPS_USER="${CH_OPS_USER:-ops_admin}"
: "${CH_OPS_PASSWORD:?CH_OPS_PASSWORD not set (source repo .env)}"

if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=true
elif [ "${1:-}" != "" ]; then
  echo "Usage: $(basename "$0") [--dry-run]" >&2
  exit 2
fi

export REPO_ROOT
# shellcheck source=/dev/null
source "$REPO_ROOT/res/scripts/lib-sql.sh" || exit 1

# shellcheck source=../../tests/config/yaml_helpers.sh
source "$REPO_ROOT/tests/config/yaml_helpers.sh" || exit 1

ch() {
  local sql="$1"
  curl -sSf --max-time 300 --user "$CH_OPS_USER:$CH_OPS_PASSWORD" "$CH_URL/" --data-binary "$sql"
}

ch_value() {
  local sql="$1"
  local out query_status first_line
  out=$(ch "$sql FORMAT TabSeparated")
  query_status=$?
  if [ "$query_status" -ne 0 ]; then
    echo "[dedupe] ERROR: ClickHouse query failed (status=$query_status)" >&2
    return 1
  fi
  read -r first_line <<< "$out"
  echo "$first_line"
}

esc() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\'/\\\'}"
  echo "'$s'"
}

# ---- load registry ----
REGISTRY_JSON=$(yaml_to_json "$REPO_ROOT/conf/model-registry.yaml")
if [ -z "$REGISTRY_JSON" ]; then
  echo "[dedupe] ERROR: could not parse conf/model-registry.yaml" >&2
  exit 1
fi

# Rename pairs only (alias != canonical), sorted.
RENAME_PAIRS=$(echo "$REGISTRY_JSON" | jq -r '
  [ .models | to_entries[] | .key as $c
    | (.value.aliases // [])[] | ascii_downcase
    | select(. != $c) | [., $c] | @tsv ][]
  ' | sort -u)

if [ -z "$RENAME_PAIRS" ]; then
  echo "[dedupe] Registry has no aliases; nothing to merge."
  exit 0
fi

# Build multiIf arms and IN list for the model column. Matching is
# CASE-INSENSITIVE (lower(model)) because historical rows predate
# normalization and may store e.g. "frank/GLM-5.2" verbatim.
MULTIIF_ARMS=""
IN_LIST=""
while IFS=$'\t' read -r alias canonical; do
  [ -n "$MULTIIF_ARMS" ] && MULTIIF_ARMS+=", "
  MULTIIF_ARMS+="lower(model) = $(esc "$alias"), $(esc "$canonical")"
  [ -n "$IN_LIST" ] && IN_LIST+=", "
  IN_LIST+=$(esc "$alias")
done <<< "$RENAME_PAIRS"
IN_LIST="(${IN_LIST})"
MODEL_MULTIIF="multiIf(${MULTIIF_ARMS}, model)"
MODEL_WHERE="lower(model) IN ${IN_LIST}"

# multiIf over model_name for billing_ledger.
MULTIIF_ARMS_MN=""
while IFS=$'\t' read -r alias canonical; do
  [ -n "$MULTIIF_ARMS_MN" ] && MULTIIF_ARMS_MN+=", "
  MULTIIF_ARMS_MN+="lower(model_name) = $(esc "$alias"), $(esc "$canonical")"
done <<< "$RENAME_PAIRS"
MODEL_NAME_MULTIIF="multiIf(${MULTIIF_ARMS_MN}, model_name)"
MODEL_NAME_WHERE="lower(model_name) IN ${IN_LIST}"

echo "[dedupe] Aliases to merge:"
echo "$RENAME_PAIRS" | while IFS=$'\t' read -r a c; do echo "  $a -> $c"; done

# ---- before snapshot ----
echo ""
echo "[dedupe] BEFORE:"
ch "$(sql_render ops/dedupe-model-history/before-snapshot.sql \
    DB="$DB" MODEL_WHERE="$MODEL_WHERE" MODEL_NAME_WHERE="$MODEL_NAME_WHERE")"

if $DRY_RUN; then
  echo ""
  echo "[dedupe] DRY RUN -- would execute:"
  echo "$(sql_render ops/dedupe-model-history/alter-usage-model.sql \
      DB="$DB" MODEL_MULTIIF="$MODEL_MULTIIF" MODEL_WHERE="$MODEL_WHERE")"
  echo "$(sql_render ops/dedupe-model-history/alter-ledger-model.sql \
      DB="$DB" MODEL_NAME_MULTIIF="$MODEL_NAME_MULTIIF" MODEL_NAME_WHERE="$MODEL_NAME_WHERE")"
  echo "request_log shadow-table swap (CREATE/INSERT SELECT/EXCHANGE/DROP)"
  echo "cost repair is owned by res/scripts/recalc-costs.sh (run: make gw-recalc-costs)"
  exit 0
fi

# ---- 1. usage_log ----
echo ""
echo "[dedupe] Merging usage_log..."
ch "$(sql_render ops/dedupe-model-history/alter-usage-model.sql \
    DB="$DB" MODEL_MULTIIF="$MODEL_MULTIIF" MODEL_WHERE="$MODEL_WHERE")"

# ---- 2. billing_ledger ----
echo "[dedupe] Merging billing_ledger..."
ch "$(sql_render ops/dedupe-model-history/alter-ledger-model.sql \
    DB="$DB" MODEL_NAME_MULTIIF="$MODEL_NAME_MULTIIF" MODEL_NAME_WHERE="$MODEL_NAME_WHERE")"

# ---- 3. request_log shadow-table swap (model is in ORDER BY) ----
echo "[dedupe] Merging request_log (shadow-table swap)..."
ch "$(sql_render ops/dedupe-model-history/drop-dedup.sql DB="$DB")"
ch "$(sql_render ops/dedupe-model-history/create-dedup.sql DB="$DB")"
ch "$(sql_render ops/dedupe-model-history/insert-dedup.sql DB="$DB" MODEL_MULTIIF="$MODEL_MULTIIF")"
ch "$(sql_render ops/dedupe-model-history/exchange-dedup.sql DB="$DB")"
ch "$(sql_render ops/dedupe-model-history/drop-dedup-final.sql DB="$DB")"

# ---- 4. cost repair is owned by the dedicated tool ----
# Historical costs are revalued by res/scripts/recalc-costs.sh. It is
# provider-scoped, audit-backed, idempotent and reuses the live cost formula
# (cost_calc.compute_cost). This script no longer rewrites cost: the old
# inline repair was provider-agnostic and could apply one provider's price
# to another provider's rows.
echo ""
echo "[dedupe] Cost repair is owned by recalc-costs.sh (dry-run by default)."
echo "         Run: make gw-recalc-costs"

# ---- verify ----
echo ""
echo "[dedupe] Verifying no alias rows remain..."
REMAINING=$(ch_value "$(sql_render ops/dedupe-model-history/remaining-count.sql \
  DB="$DB" MODEL_WHERE="$MODEL_WHERE" MODEL_NAME_WHERE="$MODEL_NAME_WHERE")")
REMAINING=${REMAINING:-1}

echo "[dedupe] AFTER:"
ch "$(sql_render ops/dedupe-model-history/after-snapshot.sql DB="$DB")"

if [ "$REMAINING" -ne 0 ]; then
  echo "[dedupe] FAIL: $REMAINING alias rows remain" >&2
  exit 1
fi

echo ""
echo "[dedupe] OK: all alias rows merged to canonical ids."
