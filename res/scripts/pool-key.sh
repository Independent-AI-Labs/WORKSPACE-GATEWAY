#!/bin/bash
set -euo pipefail

# pool-key.sh
# Manage named upstream key pools stored in OpenBao at
# secret/data/gateway/upstream-pools/<pool>. A virtual key references a pool
# via its "upstream_pool" field (see issue-key.sh --pool). key-resolver picks
# pool keys sticky-style and rotates on upstream quota/rate-limit responses:
# statuses in cooldown_on (default 429) park a key for cooldown_s; statuses in
# disable_on (default 402,403) hard-disable it in OpenBao until reset.
#
# Usage:
#   bash res/scripts/pool-key.sh create <pool> [--cooldown-s N] [--cooldown-on 429,...] [--disable-on 402,403,...]
#   bash res/scripts/pool-key.sh add <pool> <key_id> <upstream_key>
#   bash res/scripts/pool-key.sh remove <pool> <key_id>
#   bash res/scripts/pool-key.sh list [pool]
#   bash res/scripts/pool-key.sh enable <pool> <key_id>
#   bash res/scripts/pool-key.sh disable <pool> <key_id>
#   bash res/scripts/pool-key.sh reset <pool>     # re-enable ALL keys (also clears gateway cooldowns on next cache miss)
#
# Env: OPENBAO_ADDR (default http://localhost:8201), OPENBAO_TOKEN

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"

if [ -f "$ENV_FILE" ]; then
  set -a
  source "$ENV_FILE" || exit 1
  set +a
fi

OPENBAO_TOKEN="${OPENBAO_TOKEN:-2e22c6e00b0815bcada90dfecb03f3c0}"
OPENBAO_ADDR="${OPENBAO_ADDR:-http://localhost:8201}"
PREFIX="secret/data/gateway/upstream-pools"

usage() {
  sed -n '2,22p' "$0" >&2
  exit 1
}

fetch_pool() {
  local pool="$1"
  local resp
  resp=$(curl -sS -H "X-Vault-Token: ${OPENBAO_TOKEN}" \
    "${OPENBAO_ADDR}/v1/${PREFIX}/${pool}") || {
    echo "ERROR: OpenBao read failed for pool $pool" >&2; exit 1; }
  local errs
  errs=$(echo "$resp" | jq -r '.errors // [] | join("; ")')
  if [ -n "$errs" ]; then
    echo "ERROR: pool not found: $pool ($errs)" >&2
    exit 1
  fi
  echo "$resp" | jq -c '.data.data'
}

put_pool() {
  local pool="$1" data="$2"
  # Bump epoch so the gateway's in-memory disable/cooldown markers (namespaced
  # by epoch) never shadow keys after management writes like reset/enable.
  data=$(echo "$data" | jq -c '.epoch = ([(.epoch // 0) + 1, (now | floor)] | max)')
  local resp rc
  resp=$(curl -sS -X POST \
    -H "X-Vault-Token: ${OPENBAO_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc --argjson d "$data" '{data:$d}')" \
    -w '\n%{http_code}' \
    "${OPENBAO_ADDR}/v1/${PREFIX}/${pool}") && rc=0 || rc=$?
  local http_code="${resp##*$'\n'}"
  if [ "$rc" -ne 0 ] || { [ "$http_code" != "200" ] && [ "$http_code" != "204" ]; }; then
    echo "ERROR: OpenBao write failed for pool $pool (rc=$rc http=$http_code)" >&2
    echo "${resp%$'\n'*}" >&2
    exit 1
  fi
}

key_exists() {
  local data="$1" kid="$2"
  local found
  found=$(echo "$data" | jq -r --arg id "$kid" '.keys[] | select(.id==$id) | .id')
  [ -n "$found" ]
}

mask() {
  local k="$1"
  if [ "${#k}" -le 8 ]; then echo "****"; else echo "${k:0:4}...${k: -4}"; fi
}

CMD="${1:-}"
case "$CMD" in
  create)
    POOL="${2:-}"; [ -n "$POOL" ] || usage
    shift 2
    COOLDOWN_S=3600
    COOLDOWN_ON="429"
    DISABLE_ON="402,403"
    while [ $# -gt 0 ]; do
      case "$1" in
        --cooldown-s)  COOLDOWN_S="$2"; shift 2 ;;
        --cooldown-on) COOLDOWN_ON="$2"; shift 2 ;;
        --disable-on)  DISABLE_ON="$2"; shift 2 ;;
        *) echo "ERROR: unknown option: $1" >&2; exit 1 ;;
      esac
    done
    DATA=$(jq -nc \
      --argjson cs "$COOLDOWN_S" \
      --argjson co "[$(echo "$COOLDOWN_ON" | sed 's/[^0-9,]//g')]" \
      --argjson do "[$(echo "$DISABLE_ON" | sed 's/[^0-9,]//g')]" \
      '{keys: [], cooldown_s: $cs, cooldown_on: $co, disable_on: $do}')
    put_pool "$POOL" "$DATA"
    echo "=== Pool created: $POOL (cooldown_s=$COOLDOWN_S cooldown_on=[$COOLDOWN_ON] disable_on=[$DISABLE_ON]) ==="
    ;;
  add)
    POOL="${2:-}"; KID="${3:-}"; UKEY="${4:-}"
    [ -n "$POOL" ] && [ -n "$KID" ] && [ -n "$UKEY" ] || usage
    DATA=$(fetch_pool "$POOL")
    if key_exists "$DATA" "$KID"; then
      echo "ERROR: key id already exists in pool: $KID" >&2
      exit 1
    fi
    DATA=$(echo "$DATA" | jq -c --arg id "$KID" --arg k "$UKEY" '.keys += [{id:$id, key:$k, active:true}]')
    put_pool "$POOL" "$DATA"
    echo "=== Added key $KID ($(mask "$UKEY")) to pool $POOL ==="
    ;;
  remove)
    POOL="${2:-}"; KID="${3:-}"
    [ -n "$POOL" ] && [ -n "$KID" ] || usage
    DATA=$(fetch_pool "$POOL")
    if ! key_exists "$DATA" "$KID"; then
      echo "ERROR: key id not found in pool: $KID" >&2
      exit 1
    fi
    DATA=$(echo "$DATA" | jq -c --arg id "$KID" '.keys |= map(select(.id != $id))')
    put_pool "$POOL" "$DATA"
    echo "=== Removed key $KID from pool $POOL ==="
    ;;
  list)
    POOL="${2:-}"
    if [ -n "$POOL" ]; then
      DATA=$(fetch_pool "$POOL")
      echo "pool: $POOL (cooldown_s=$(echo "$DATA" | jq -r '.cooldown_s // 3600') cooldown_on=$(echo "$DATA" | jq -c '.cooldown_on // [429]') disable_on=$(echo "$DATA" | jq -c '.disable_on // [402,403]') epoch=$(echo "$DATA" | jq -r '.epoch // 0'))"
      echo "$DATA" | jq -r '.keys[] | "  \(.id)\tactive=\(.active)\t\(.key[0:4])...\(.key[-4:])"'
    else
      curl -sS -H "X-Vault-Token: ${OPENBAO_TOKEN}" \
        "${OPENBAO_ADDR}/v1/secret/metadata/gateway/upstream-pools?list=true" \
        | jq -r '.data.keys[]?'
    fi
    ;;
  enable|disable)
    POOL="${2:-}"; KID="${3:-}"
    [ -n "$POOL" ] && [ -n "$KID" ] || usage
    ACTIVE=true; [ "$CMD" = "disable" ] && ACTIVE=false
    DATA=$(fetch_pool "$POOL")
    if ! key_exists "$DATA" "$KID"; then
      echo "ERROR: key id not found in pool: $KID" >&2
      exit 1
    fi
    DATA=$(echo "$DATA" | jq -c --arg id "$KID" --argjson a "$ACTIVE" \
      '.keys |= map(if .id==$id then .active=$a else . end)')
    put_pool "$POOL" "$DATA"
    echo "=== Key $KID in pool $POOL: active=$ACTIVE ==="
    ;;
  reset)
    POOL="${2:-}"
    [ -n "$POOL" ] || usage
    DATA=$(fetch_pool "$POOL")
    DATA=$(echo "$DATA" | jq -c '.keys |= map(.active = true)')
    put_pool "$POOL" "$DATA"
    echo "=== Pool $POOL reset: all keys re-enabled (epoch bumped; stale markers orphaned) ==="
    ;;
  *)
    usage
    ;;
esac
