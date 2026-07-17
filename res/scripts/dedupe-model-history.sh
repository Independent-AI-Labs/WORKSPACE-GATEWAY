#!/bin/bash
set -euo pipefail

# dedupe-model-history.sh
# One-off historical merge: rewrite every alias-shaped model string in
# ClickHouse to its canonical id from conf/model-registry.yaml, then
# recompute cost for cost_source='unknown' rows whose canonical model is
# priced by the gateway catalog.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

GATEWAY_URL="${GATEWAY_URL:-http://127.0.0.1:9080}"
CLICKHOUSE_HOST="${CLICKHOUSE_HOST:-localhost}"
CLICKHOUSE_PORT="${CLICKHOUSE_PORT:-8123}"
CH_URL="http://${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}"
DB="${DATABASE:-llm_gateway}"
DRY_RUN=false

if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=true
elif [ "${1:-}" != "" ]; then
  echo "Usage: $(basename "$0") [--dry-run]" >&2
  exit 2
fi

# shellcheck source=../../tests/config/yaml_helpers.sh
source "$REPO_ROOT/tests/config/yaml_helpers.sh" || exit 1

ch() {
  local sql="$1"
  curl -sSf --max-time 300 "$CH_URL/" --data-binary "$sql"
}

ch_value() {
  local sql="$1"
  local out rc first_line
  out=$(ch "$sql FORMAT TabSeparated")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "[dedupe] ERROR: ClickHouse query failed (rc=$rc)" >&2
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

# Full alias map (alias -> canonical, canonical maps to itself), lowercased.
ALIAS_MAP_JSON=$(echo "$REGISTRY_JSON" | jq -c '
  [ .models | to_entries[] | .key as $c
    | ([$c] + [(.value.aliases // [])[] | ascii_downcase])[]
    | {key: ., value: $c} ]
  | from_entries')

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
ch "SELECT 'usage_log' AS t, model, count(), toFloat64(sum(cost)) FROM ${DB}.usage_log WHERE ${MODEL_WHERE} GROUP BY model
    UNION ALL
    SELECT 'billing_ledger', model_name, count(), toFloat64(sum(cost)) FROM ${DB}.billing_ledger WHERE ${MODEL_NAME_WHERE} GROUP BY model_name
    UNION ALL
    SELECT 'request_log', model, count(), toFloat64(0) FROM ${DB}.request_log WHERE ${MODEL_WHERE} GROUP BY model
    ORDER BY 1, 2 FORMAT PrettyCompact"

if $DRY_RUN; then
  echo ""
  echo "[dedupe] DRY RUN -- would execute:"
  echo "ALTER TABLE ${DB}.usage_log UPDATE model_raw = model, model = ${MODEL_MULTIIF} WHERE ${MODEL_WHERE} SETTINGS mutations_sync = 1;"
  echo "ALTER TABLE ${DB}.billing_ledger UPDATE model_raw = model_name, model_name = ${MODEL_NAME_MULTIIF} WHERE ${MODEL_NAME_WHERE} SETTINGS mutations_sync = 1;"
  echo "request_log shadow-table swap (CREATE/INSERT SELECT/EXCHANGE/DROP)"
  echo "cost repair for cost_source='unknown' rows priced by the gateway catalog"
  exit 0
fi

# ---- 1. usage_log ----
echo ""
echo "[dedupe] Merging usage_log..."
ch "ALTER TABLE ${DB}.usage_log
    UPDATE model_raw = model, model = ${MODEL_MULTIIF}
    WHERE ${MODEL_WHERE}
    SETTINGS mutations_sync = 1"

# ---- 2. billing_ledger ----
echo "[dedupe] Merging billing_ledger..."
ch "ALTER TABLE ${DB}.billing_ledger
    UPDATE model_raw = model_name, model_name = ${MODEL_NAME_MULTIIF}
    WHERE ${MODEL_NAME_WHERE}
    SETTINGS mutations_sync = 1"

# ---- 3. request_log shadow-table swap (model is in ORDER BY) ----
echo "[dedupe] Merging request_log (shadow-table swap)..."
ch "DROP TABLE IF EXISTS ${DB}.request_log_dedup"
ch "CREATE TABLE ${DB}.request_log_dedup AS ${DB}.request_log"
ch "INSERT INTO ${DB}.request_log_dedup
    SELECT * REPLACE (${MODEL_MULTIIF} AS model)
    FROM ${DB}.request_log"
ch "EXCHANGE TABLES ${DB}.request_log AND ${DB}.request_log_dedup"
ch "DROP TABLE ${DB}.request_log_dedup"

# ---- 4. cost repair for unknown rows priced by the catalog ----
echo ""
echo "[dedupe] Fetching gateway catalog pricing..."
PROVIDER_LIST_JSON=$(curl -sSf --max-time 30 "${GATEWAY_URL}/gateway/providers") || {
  echo "[dedupe] ERROR: failed to fetch ${GATEWAY_URL}/gateway/providers" >&2
  exit 1
}

# The list endpoint returns summaries only; fetch each provider detail.
CATALOG_JSON="[]"
while read -r pid; do
  [ -z "$pid" ] && continue
  DETAIL=$(curl -sSf --max-time 30 "${GATEWAY_URL}/gateway/providers/${pid}") || {
    echo "[dedupe] ERROR: failed to fetch provider ${pid}" >&2
    exit 1
  }
  CATALOG_JSON=$(jq -c --argjson d "$DETAIL" '. + [$d]' <<< "$CATALOG_JSON")
done < <(jq -r '.[].id' <<< "$PROVIDER_LIST_JSON")

PRICED_MODELS=$(echo "$CATALOG_JSON" | jq -r --argjson am "$ALIAS_MAP_JSON" '
  [ .[] | .id as $p | (.models // {}) | to_entries[]
    | select(.value.cost != null)
    | { m: (.key | ascii_downcase | . as $k | ($am[$k] // ($k | split("/")[-1] | . as $s | ($am[$s] // $s)))),
        p: $p,
        i: (.value.cost.input // 0),
        o: (.value.cost.output // 0),
        cr: (.value.cost.cache_read // 0) } ]
  | sort_by(.m, .p)
  | unique_by(.m)[]
  | [.m, .i, .o, .cr] | @tsv')

if [ -z "$PRICED_MODELS" ]; then
  echo "[dedupe] WARNING: no priced models in gateway catalog; skipping cost repair" >&2
else
  echo "[dedupe] Repairing cost for unknown rows with priced canonical models..."
  while IFS=$'\t' read -r model input output cache_read; do
    affected=$(ch_value "SELECT count() FROM ${DB}.usage_log WHERE cost_source = 'unknown' AND model = $(esc "$model")")
    affected=${affected:-0}
    if [ "$affected" -eq 0 ]; then
      continue
    fi
    echo "  $model: $affected rows (in=$input out=$output cr=$cache_read)"
    ch "ALTER TABLE ${DB}.usage_log
        UPDATE
          cost = (
            greatest(prompt_tokens - cached_tokens, 0) * ${input}
            + greatest(completion_tokens - reasoning_tokens, 0) * ${output}
            + cached_tokens * ${cache_read}
            + reasoning_tokens * ${output}
          ) / 1000000,
          cost_source = 'computed'
        WHERE cost_source = 'unknown' AND model = $(esc "$model")
        SETTINGS mutations_sync = 1"
  done <<< "$PRICED_MODELS"
fi

# ---- verify ----
echo ""
echo "[dedupe] Verifying no alias rows remain..."
REMAINING=$(ch_value "
  SELECT
    (SELECT count() FROM ${DB}.usage_log WHERE ${MODEL_WHERE})
    + (SELECT count() FROM ${DB}.billing_ledger WHERE ${MODEL_NAME_WHERE})
    + (SELECT count() FROM ${DB}.request_log WHERE ${MODEL_WHERE})")
REMAINING=${REMAINING:-1}

echo "[dedupe] AFTER:"
ch "SELECT model, cost_source, count(), sum(cost) FROM ${DB}.usage_log GROUP BY model, cost_source ORDER BY count() DESC FORMAT PrettyCompact"

if [ "$REMAINING" -ne 0 ]; then
  echo "[dedupe] FAIL: $REMAINING alias rows remain" >&2
  exit 1
fi

echo ""
echo "[dedupe] OK: all alias rows merged to canonical ids."
