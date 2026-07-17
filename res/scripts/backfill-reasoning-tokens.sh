#!/bin/bash
set -euo pipefail

# Backfill reasoning_tokens in usage_log from reasoning_content in request_log.
#
# The GLM-5.2 provider streams reasoning content via choices[0].delta.reasoning_content
# in SSE chunks but never sets usage.reasoning_tokens.  This script:
#   1. Queries request_log for rows with reasoning_content text
#   2. Parses the SSE stream, accumulates reasoning_content, counts approx tokens
#   3. INSERTs computed values into a reasoning_backfill table
#   4. UPDATEs usage_log by event_id match (forward path must be deployed first)
#   5. Reports results
#
# Usage:  ./backfill-reasoning-tokens.sh [--dry-run] [--limit N] [--days N]
#
# Depends: curl, jq

CLICKHOUSE_HOST="${CLICKHOUSE_HOST:-localhost}"
CLICKHOUSE_PORT="${CLICKHOUSE_PORT:-8123}"
CH_URL="http://${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}"

DRY_RUN=false
LIMIT=0
DAYS=7
BATCH_SIZE=200
DATABASE="llm_gateway"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --days) DAYS="$2"; shift 2 ;;
    --database) DATABASE="$2"; shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

DB="$DATABASE"

ch() {
  local sql="$1"
  curl -sSf --max-time 30 "$CH_URL/" --data-binary "$sql"
}

esc() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\'/\\\'}"
  echo "'$s'"
}

# Count approx tokens from reasoning_content in an SSE response body.
# Input: raw SSE body (multi-line with data: JSON chunks)
# Output: integer token count (ceil(char_len / 4))
count_reasoning_tokens() {
  local body="$1"
  local acc
  acc=$(echo "$body" \
    | grep '^data: ' \
    | sed 's/^data: //' \
    | grep -v '^\[DONE\]$' \
    | jq -r '.choices[0].delta.reasoning_content // empty' \
    | tr -d '\n')
  local len=${#acc}
  [[ "$len" -eq 0 ]] && echo 0 && return
  echo $(( (len + 3) / 4 ))
}


# ---- main ----
echo "[backfill] ClickHouse: $CH_URL"
echo "[backfill] Dry run: $DRY_RUN, Limit: $LIMIT, Days: $DAYS"

CUTOFF=""
if CUTOFF=$(date -u -d "@$(( $(date +%s) - DAYS * 86400 ))" +%Y-%m-%dT%H:%M:%S); then
  :
elif CUTOFF=$(date -u -v-"$DAYS"d +%Y-%m-%dT%H:%M:%S); then
  :
else
  CUTOFF=$(date -u -d "$DAYS days ago" +%Y-%m-%dT%H:%M:%S)
fi
if [ -z "$CUTOFF" ]; then
  echo "[backfill] ERROR: could not compute cutoff date" >&2; exit 1
fi

# Stream rows as JSONL (handles multi-line resp_body properly)
QUERY="SELECT event_id, model, key_id, toString(timestamp) AS ts, resp_body
FROM ${DB}.request_log
WHERE resp_body LIKE '%reasoning_content\":\"%'
  AND event_id != ''
  AND timestamp >= '$CUTOFF'
ORDER BY timestamp DESC"
[[ "$LIMIT" -gt 0 ]] && QUERY+=" LIMIT $LIMIT"
QUERY+=" FORMAT JSONEachRow"

echo "[backfill] Fetching rows..."
FETCH_OUT=$(ch "$QUERY") || { echo "[backfill] ERROR: fetch failed" >&2; exit 1; }
TOTAL=$(echo "$FETCH_OUT" | grep -c '^{' || rc=$?)
if [[ "${rc:-0}" -ne 0 && "${rc:-0}" -ne 1 ]]; then
    echo "[backfill] ERROR: grep failed rc=$rc" >&2; exit 1
fi
TOTAL="${TOTAL:-0}"
echo "[backfill] Found $TOTAL rows with reasoning content"
[[ "$TOTAL" -eq 0 ]] && echo "[backfill] Nothing to do." && exit 0

# Step 2: parse SSE and compute tokens
echo "[backfill] Computing reasoning tokens..."
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

PROCESSED=0
CURRENT=0
while IFS= read -r json_row; do
  [[ -z "$json_row" ]] && continue
  CURRENT=$(( CURRENT + 1 ))

  event_id=$(echo "$json_row" | jq -r '.event_id')
  model=$(echo "$json_row" | jq -r '.model')
  key_id=$(echo "$json_row" | jq -r '.key_id')
  ts=$(echo "$json_row" | jq -r '.ts')
  body=$(echo "$json_row" | jq -r '.resp_body')

  tokens=$(count_reasoning_tokens "$body")
  [[ "$tokens" -eq 0 ]] && continue

  eid=$(esc "$event_id")
  em=$(esc "$model")
  ek=$(esc "$key_id")
  ets=$(esc "$ts")

  echo "$eid|$em|$ek|$ets|$tokens|${#body}" >> "$TMPFILE"
  PROCESSED=$(( PROCESSED + 1 ))

  if [[ $(( CURRENT % 50 )) -eq 0 ]] || [[ "$CURRENT" -eq "$TOTAL" ]]; then
    echo -ne "[backfill]   $CURRENT / $TOTAL (with tokens: $PROCESSED)\r" >&2
  fi
done <<< "$FETCH_OUT"
echo >&2
echo "[backfill] Computed reasoning tokens for $PROCESSED rows"
[[ "$PROCESSED" -eq 0 ]] && echo "[backfill] No extractable reasoning content." && exit 0

# Step 3: create + populate temp table
echo "[backfill] Creating reasoning_backfill table..."
ch "DROP TABLE IF EXISTS ${DB}.reasoning_backfill" || { echo "[backfill] WARN: DROP reasoning_backfill failed (continuing - table may not exist)" >&2; }
ch "
  CREATE TABLE ${DB}.reasoning_backfill (
    event_id         String,
    model            String,
    key_id           String,
    ts               DateTime64(3),
    reasoning_tokens  UInt32,
    reasoning_chars   UInt32
  ) ENGINE = MergeTree()
  ORDER BY (event_id)
" || { echo "[backfill] ERROR: create table failed" >&2; exit 1; }

echo "[backfill] Inserting into temp table..."
INSERTED=0
FAILED=0
BUF=""
while IFS='|' read -r eid em ek ets tokens chars; do
  if [[ -n "$BUF" ]]; then BUF+=","; fi
  BUF+="($eid,$em,$ek,$ets,$tokens,$chars)"
  INSERTED=$(( INSERTED + 1 ))

  if [[ $(( INSERTED % BATCH_SIZE )) -eq 0 ]] || [[ "$INSERTED" -eq "$PROCESSED" ]]; then
    if ! ch "
      INSERT INTO ${DB}.reasoning_backfill
      (event_id, model, key_id, ts, reasoning_tokens, reasoning_chars)
      VALUES $BUF
    "; then
      FAILED=$(( FAILED + 1 ))
      echo "[backfill] ERROR: batch insert failed at row $INSERTED (batch $(( INSERTED / BATCH_SIZE )))" >&2
    fi
    BUF=""
    echo -ne "[backfill]   Inserted $INSERTED / $PROCESSED (failed=$FAILED)        \r" >&2
  fi
done < "$TMPFILE"
# flush remaining
if [[ -n "$BUF" ]]; then
  if ! ch "
    INSERT INTO ${DB}.reasoning_backfill
    (event_id, model, key_id, ts, reasoning_tokens, reasoning_chars)
    VALUES $BUF
  "; then
    FAILED=$(( FAILED + 1 ))
    echo "[backfill] ERROR: final batch insert failed" >&2
  fi
fi
echo >&2

# Step 4: count matched usage_log rows
MATCHED=$(ch "
  SELECT count()
  FROM ${DB}.usage_log
  WHERE reasoning_tokens = 0
    AND event_id IN (SELECT event_id FROM ${DB}.reasoning_backfill)
  FORMAT TabSeparated
" || { echo "[backfill] ERROR: matched-count query failed" >&2; echo "0"; })
echo "[backfill] usage_log rows with event_id match (reasoning_tokens=0): $MATCHED"

# Sample
echo "[backfill] Sample computed values:"
head -5 "$TMPFILE" | while IFS='|' read -r eid em ek ets tokens chars; do
  echo "  $eid: model=$em, chars=$chars, tokens=$tokens"
done

if $DRY_RUN; then
  echo "[backfill] DRY RUN -- no data written to usage_log."
  echo "[backfill] Data in ${DB}.reasoning_backfill. Drop: DROP TABLE ${DB}.reasoning_backfill"
  exit 0
fi

# Step 5: UPDATE usage_log row by row
if [[ "$MATCHED" -gt 0 ]]; then
  echo "[backfill] Updating $MATCHED usage_log rows..."
  ch "
    SELECT event_id, reasoning_tokens
    FROM ${DB}.reasoning_backfill
    WHERE event_id IN (
      SELECT event_id FROM ${DB}.usage_log WHERE reasoning_tokens = 0
    )
    FORMAT TabSeparated
  " | while IFS=$'\t' read -r eid rt; do
    [[ "$eid" == "event_id" ]] && continue
    eeid=$(esc "$eid")
    if ! ch "
      ALTER TABLE ${DB}.usage_log
      UPDATE reasoning_tokens = $rt
      WHERE event_id = $eeid AND reasoning_tokens = 0
      SETTINGS mutations_sync = 1
    "; then
      FAILED=$(( FAILED + 1 ))
      echo "[backfill] ERROR: ALTER failed for $eid" >&2
    fi
  done
  echo "[backfill] UPDATE done."
else
  echo "[backfill] No rows to update (event_ids don't match historical data)."
  echo "[backfill] Forward fix handles new requests going forward."
fi

# Step 6: verify
VERIFIED=$(ch "
  SELECT countIf(reasoning_tokens > 0), sum(reasoning_tokens)
  FROM ${DB}.usage_log
  FORMAT TabSeparated
" || { echo "[backfill] ERROR: verify query failed" >&2; echo "0 0"; })
echo "[backfill] Overall usage_log (with_reasoning / total_reasoning): $VERIFIED"

ch "DROP TABLE IF EXISTS ${DB}.reasoning_backfill" || { echo "[backfill] WARN: final DROP reasoning_backfill failed" >&2; }
echo "[backfill] Done."
