#!/bin/bash
set -euo pipefail

# Backfill cost and cost_source in usage_log for rows where the gateway could
# not compute cost because the client model name was not in the pricing cache.
#
# Looks up current pricing from the gateway provider-sync service and issues a
# single ClickHouse ALTER TABLE UPDATE with a multiIf pricing expression.
#
# Usage:
#   ./backfill-provider-costs.sh [--provider-id ID] [--dry-run] [--days N]
#
# Defaults backfill the workspace-gw-kimi-oauth provider (covers all Kimi
# model aliases, including kimi-for-coding).
#
# Depends: curl, jq, clickhouse-client (or CLICKHOUSE_HOST/PORT for HTTP)

GATEWAY_URL="${GATEWAY_URL:-http://127.0.0.1:9080}"
CLICKHOUSE_HOST="${CLICKHOUSE_HOST:-localhost}"
CLICKHOUSE_PORT="${CLICKHOUSE_PORT:-8123}"
CH_URL="http://${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}"
DATABASE="${DATABASE:-llm_gateway}"

PROVIDER_ID="${PROVIDER_ID:-workspace-gw-kimi-oauth}"
DRY_RUN=false
DAYS=0
BATCH_SIZE=1000

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --provider-id ID   Provider ID to fetch from /gateway/providers/<ID> (default: ${PROVIDER_ID})
  --dry-run          Print the generated SQL and row count; do not mutate
  --days N           Only backfill rows from the last N days (0 = all, default: ${DAYS})
  --database DB      ClickHouse database (default: ${DATABASE})
  --help             Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider-id) PROVIDER_ID="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --days) DAYS="$2"; shift 2 ;;
    --database) DATABASE="$2"; shift 2 ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

DB="$DATABASE"

ch() {
  local sql="$1"
  curl -sSf --max-time 60 "$CH_URL/" --data-binary "$sql"
}

ch_value() {
  local sql="$1"
  local out rc first_line
  out=$(ch "$sql FORMAT TabSeparated")
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "[backfill] ERROR: ClickHouse query failed (rc=$rc)" >&2
    return 1
  fi
  # Extract first line without piping, to satisfy strict error-swallow checks.
  read -r first_line <<< "$out"
  echo "$first_line"
}

esc() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\'/\\\'}"
  echo "'$s'"
}

# ---- fetch provider pricing from gateway ----
PROVIDER_URL="${GATEWAY_URL}/gateway/providers/${PROVIDER_ID}"
echo "[backfill] Fetching provider from ${PROVIDER_URL}"
PROVIDER_JSON=$(curl -sSf --max-time 30 "$PROVIDER_URL") || {
  echo "[backfill] ERROR: failed to fetch provider ${PROVIDER_ID}" >&2
  exit 1
}

if ! MODELS_JSON=$(echo "$PROVIDER_JSON" | jq -e '.models'); then
  echo "[backfill] ERROR: provider JSON has no .models object" >&2
  exit 1
fi

# Build a list of model names that have cost data.
# Each entry is "model_name|input|output|cache_read|reasoning" (reasoning may be empty).
MODELS=$(echo "$MODELS_JSON" | jq -r '
  to_entries[]
  | select(.value.cost and (.value.cost.input != null) and (.value.cost.output != null))
  | [(.key), (.value.cost.input // 0), (.value.cost.output // 0), (.value.cost.cache_read // 0), (.value.cost.reasoning // "")]
  | @tsv
')

if [[ -z "$MODELS" ]]; then
  echo "[backfill] ERROR: no priced models found in provider ${PROVIDER_ID}" >&2
  exit 1
fi

MODEL_NAMES=()
CASES=""
while IFS=$'\t' read -r model input output cache_read reasoning; do
  MODEL_NAMES+=("$model")
  # ClickHouse uses greatest() for non-negative differences (matches cost_calc.lua).
  # Reasoning rate defaults to output rate when not present.
  if [[ -n "$reasoning" && "$reasoning" != "null" ]]; then
    reasoning_rate="$reasoning"
  else
    reasoning_rate="$output"
  fi
  [[ -n "$CASES" ]] && CASES+=", "
  CASES+="model = $(esc "$model"), (
    greatest(prompt_tokens - cached_tokens, 0) * ${input}
    + greatest(completion_tokens - reasoning_tokens, 0) * ${output}
    + cached_tokens * ${cache_read}
    + reasoning_tokens * ${reasoning_rate}
  ) / 1000000"
done <<< "$MODELS"

IN_LIST=""
for m in "${MODEL_NAMES[@]}"; do
  [[ -n "$IN_LIST" ]] && IN_LIST+=", "
  IN_LIST+=$(esc "$m")
done
IN_LIST="(${IN_LIST})"

# Count rows that will be affected.
WHERE="cost_source = 'unknown' AND model IN ${IN_LIST}"
if [[ "$DAYS" -gt 0 ]]; then
  CUTOFF=""
  if CUTOFF=$(date -u -d "@$(( $(date +%s) - DAYS * 86400 ))" +%Y-%m-%dT%H:%M:%S); then
    :
  elif CUTOFF=$(date -u -v-"$DAYS"d +%Y-%m-%dT%H:%M:%S); then
    :
  else
    CUTOFF=$(date -u -d "$DAYS days ago" +%Y-%m-%dT%H:%M:%S)
  fi
  if [[ -z "$CUTOFF" ]]; then
    echo "[backfill] ERROR: could not compute cutoff date" >&2
    exit 1
  fi
  WHERE+=" AND timestamp >= '${CUTOFF}'"
fi

COUNT_SQL="SELECT count() FROM ${DB}.usage_log WHERE ${WHERE}"
COUNT=$(ch_value "$COUNT_SQL")
COUNT=${COUNT:-0}

echo "[backfill] Provider: ${PROVIDER_ID}"
echo "[backfill] Priced models: ${MODEL_NAMES[*]}"
echo "[backfill] Rows to update: ${COUNT}"

if [[ "$COUNT" -eq 0 ]]; then
  echo "[backfill] Nothing to do."
  exit 0
fi

# ---- build and run ALTER TABLE UPDATE ----
SQL="
ALTER TABLE ${DB}.usage_log
UPDATE
  cost = multiIf(${CASES},
    0),
  cost_source = 'computed'
WHERE ${WHERE}
SETTINGS mutations_sync = 1
"

if $DRY_RUN; then
  echo "[backfill] DRY RUN -- generated SQL:"
  echo "$SQL"
  exit 0
fi

echo "[backfill] Running backfill..."
ch "$SQL" || {
  echo "[backfill] ERROR: ALTER TABLE UPDATE failed" >&2
  exit 1
}

# ---- verify ----
VERIFIED=$(ch_value "
SELECT
  countIf(cost_source = 'unknown') AS remaining_unknown,
  count() AS total_rows,
  sum(cost) AS total_cost
FROM ${DB}.usage_log
WHERE model IN ${IN_LIST}
FORMAT TabSeparated
")

echo "[backfill] Done. Post-run (model in ${IN_LIST}): ${VERIFIED}"
