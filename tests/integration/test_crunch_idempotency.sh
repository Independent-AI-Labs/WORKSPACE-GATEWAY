#!/bin/bash
set -euo pipefail

# Integration test: crunch-usefulness.sh is idempotent (REQ-USEFULNESS-
# TELEMETRY FR-2.2) and emits correct signals for known messages (FR-2.7,
# FR-4.x). Seeds one aligned hourly window with synthetic request_log rows,
# runs the cruncher twice, and asserts byte-identical request_signals.
# Skips cleanly when ClickHouse or the apisix container is unavailable.

CLICKHOUSE_HOST="${CLICKHOUSE_HOST:-localhost}"
CLICKHOUSE_PORT="${CLICKHOUSE_PORT:-8123}"
CH_URL="http://${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}"

_SELF="${BASH_SOURCE[0]}"
case "$_SELF" in
    /proc/*) _SELF="${SHG_SCRIPT_PATH:-$_SELF}" ;;
esac
REPO_ROOT="$(cd "$(dirname "$_SELF")/../.." && pwd)"
CRUNCH="$REPO_ROOT/res/scripts/crunch-usefulness.sh"

export REPO_ROOT
# shellcheck source=../../res/scripts/lib-sql.sh
source "$REPO_ROOT/res/scripts/lib-sql.sh" || exit 1

pass=0
fail=0

ok() { echo "[PASS] $1"; pass=$((pass + 1)); }
ko() { echo "[FAIL] $1"; fail=$((fail + 1)); }

CH_PROBE=""
if ! CH_PROBE=$(curl -sSf --max-time 3 "$CH_URL/ping"); then
    echo "[SKIP] ClickHouse not reachable, skipping crunch idempotency test"
    exit 0
fi
if [ -z "${CH_OPS_PASSWORD:-}" ]; then
    echo "[SKIP] CH_OPS_PASSWORD not set (source repo .env), skipping crunch idempotency test"
    exit 0
fi

APSX_RC=0
APSX_LIST=$(podman ps --format '{{.Names}}') || APSX_RC=$?
APISIX_CONTAINER="${APISIX_CONTAINER:-}"
if [ -z "$APISIX_CONTAINER" ] && [ "$APSX_RC" -eq 0 ]; then
    # Prefer an apisix container that actually has the usefulness mounts
    # (the dev compose one); a stale prod apisix may also be running.
    APSX_CANDS_RC=0
    APSX_CANDS=$(printf '%s\n' "$APSX_LIST" | grep apisix) || { APSX_CANDS_RC=$?; APSX_CANDS=""; }
    for c in $APSX_CANDS; do
        if podman exec "$c" test -f /usr/local/apisix/usefulness/cruncher.lua; then
            APISIX_CONTAINER="$c"
            break
        fi
    done
fi
if [ -z "$APISIX_CONTAINER" ]; then
    echo "[SKIP] no running apisix container with usefulness mounts, skipping crunch idempotency test"
    exit 0
fi

ch() (
  sql="$1"
  cfg="$(mktemp)"
  trap 'rm -f "$cfg"' EXIT
  printf 'user = "%s:%s"\n' "${CH_OPS_USER:-ops_admin}" "$CH_OPS_PASSWORD" > "$cfg"
  curl -sSf --max-time 60 \
      --config "$cfg" \
      "$CH_URL/" --data-binary "$sql"
)

# Aligned window: the full hour 3 hours ago.
NOW_S=$(( $(date +%s) - 3 * 3600 ))
W=$(( NOW_S - (NOW_S % 3600) ))
WT0="$(date -u -d "@$W" '+%F %T')"
WT1="$(date -u -d "@$((W + 3600))" '+%F %T')"

ch "$(sql_render tests/crunch-idempotency/delete-signals-window.sql "WT0=$WT0" "WT1=$WT1")"

# JSONEachRow rows: req_body values are embedded as raw JSON objects
# (SQL-string quoting would be invalid inside JSONEachRow).
FOLLOWUP_BODY='{"model":"test-model","messages":[{"role":"user","content":"hi"},{"role":"assistant","content":"answer"},{"role":"user","content":"this is shit and pathetic"}]}'
FIRSTTURN_BODY='{"model":"test-model","messages":[{"role":"user","content":"hello please help me"}]}'
PHRASE_BODY='{"model":"test-model","messages":[{"role":"user","content":"hi"},{"role":"assistant","content":"answer"},{"role":"user","content":"thats not what i asked for"}]}'
FRICTION_BODY='{"model":"test-model","messages":[{"role":"user","content":"hi"},{"role":"assistant","content":"answer"},{"role":"tool","content":"BLOCKED: bash -c '\''rm -rf /tmp/x'\'' (rm-rootfs) (2026-09-16T00:00:00+00:00)"},{"role":"tool","content":"The user rejected permission to use this specific tool call."},{"role":"user","content":"try again please"}]}'

# Bodies live in request_bodies since migration 000010; seed both tables
# with shared event_ids (request_log keeps metadata only).
ch "$(sql_render tests/crunch-idempotency/insert-request-log.sql "WT0=$WT0")"

ch "$(sql_render tests/crunch-idempotency/insert-request-bodies.sql \
    "WT0=$WT0" "FOLLOWUP_BODY=$FOLLOWUP_BODY" "FIRSTTURN_BODY=$FIRSTTURN_BODY" \
    "PHRASE_BODY=$PHRASE_BODY" "FRICTION_BODY=$FRICTION_BODY")"

RUN1=$(CLICKHOUSE_HOST="$CLICKHOUSE_HOST" CLICKHOUSE_PORT="$CLICKHOUSE_PORT" \
       APISIX_CONTAINER="$APISIX_CONTAINER" \
       SHG_SCRIPT_PATH="$CRUNCH" bash "$CRUNCH" --since "${WT0}") \
  && ok "cruncher run 1 succeeds" || ko "cruncher run 1 fails"

SIG1=$(ch "$(sql_render tests/crunch-idempotency/signals-window.sql "WT0=$WT0" "WT1=$WT1" "PREFIX=crunch-test-")")

echo "--- signals after run 1 ---"
printf '%s\n' "$SIG1"
echo "---------------------------"

N_ROWS=$(printf '%s\n' "$SIG1" | grep -c . ) || N_ROWS=0
[ "$N_ROWS" = "5" ] && ok "all 5 rows recorded (unparseable row kept, FR-2.7)" || ko "expected 5 signal rows, got $N_ROWS"

# curl used to join multiple --data-binary parts with '&', corrupting the
# first TSV row of every block insert to "&<request_id>"
N_AMP=$(ch "$(sql_render tests/crunch-idempotency/count-amp-request-ids.sql)") || N_AMP="?"; [ "$N_AMP" = "0" ] && ok "no ampersand-corrupted request_ids (curl multi-part join guard)" || ko "found $N_AMP request_ids starting with '&'"

ROW_A=$(printf '%s\n' "$SIG1" | grep -a $'^crunch-test-a\t')
echo "$ROW_A" | grep -q $'crunch-test-a\t1\t1\t1\t1\tshit' && ok "row A: followup profanity detected + canonicalized" || ko "row A wrong: $ROW_A"
echo "$ROW_A" | grep -q $'2\t' && ok "row A: profanity + VADER counted (signal_count 2)" || ko "row A signal_count wrong: $ROW_A"

ROW_B=$(printf '%s\n' "$SIG1" | grep -a $'^crunch-test-b\t')
echo "$ROW_B" | grep -q $'crunch-test-b\t0\t1\t0\t0' && ok "row B: first-turn clean, parsed" || ko "row B wrong: $ROW_B"

ROW_C=$(printf '%s\n' "$SIG1" | grep -a $'^crunch-test-c\t')
echo "$ROW_C" | grep -q 'not what i asked' && ok "row C: frustration phrase matched" || ko "row C wrong: $ROW_C"

ROW_D=$(printf '%s\n' "$SIG1" | grep -a $'^crunch-test-d\t')
echo "$ROW_D" | grep -q $'crunch-test-d\t0\t0\t0' && ok "row D: unparseable body recorded parsed=0" || ko "row D wrong: $ROW_D"

ROW_E=$(printf '%s\n' "$SIG1" | grep -a $'^crunch-test-e\t')
echo "$ROW_E" | grep -q 'rm-rootfs' && ok "row E: guard rule id extracted from BLOCKED marker" || ko "row E guard_rules wrong: $ROW_E"
echo "$ROW_E" | grep -q $'1\trm-rootfs\t1\t0' && ok "row E: friction counts (1 block, 1 user rejection, 0 rule denial)" || ko "row E friction wrong: $ROW_E"

# Idempotency: second run over the same window must converge byte-identically.
RUN2=$(CLICKHOUSE_HOST="$CLICKHOUSE_HOST" CLICKHOUSE_PORT="$CLICKHOUSE_PORT" \
       APISIX_CONTAINER="$APISIX_CONTAINER" \
       SHG_SCRIPT_PATH="$CRUNCH" bash "$CRUNCH" --since "${WT0}") \
  && ok "cruncher run 2 succeeds" || ko "cruncher run 2 fails"

SIG2=$(ch "$(sql_render tests/crunch-idempotency/signals-window.sql "WT0=$WT0" "WT1=$WT1" "PREFIX=crunch-test-")")

if [ "$SIG1" = "$SIG2" ]; then
  ok "re-run over same window is byte-identical (idempotent, FR-2.2)"
else
  ko "re-run diverged"
  echo "run1: $SIG1"
  echo "run2: $SIG2"
fi

N_ROWS_2=$(printf '%s\n' "$SIG2" | grep -c . ) || N_ROWS_2=0
[ "$N_ROWS_2" = "5" ] && ok "no duplicate rows after re-run" || ko "row count after re-run: $N_ROWS_2"

# Cleanup: remove seeded request_log + request_bodies rows, then re-crunch
# the window so any REAL pre-existing signals for these hours are restored
# (idempotent replay).
CLEAN_DEL=$(ch "$(sql_render tests/crunch-idempotency/delete-request-log-prefix.sql "WT0=$WT0" "WT1=$WT1" "PREFIX=crunch-test-")")
CLEAN_DEL_BODIES=$(ch "$(sql_render tests/crunch-idempotency/delete-request-bodies-prefix.sql "WT0=$WT0" "WT1=$WT1" "PREFIX=crunch-test-")")
CLEAN_REPLAY=""
if CLEAN_REPLAY=$(CLICKHOUSE_HOST="$CLICKHOUSE_HOST" CLICKHOUSE_PORT="$CLICKHOUSE_PORT" \
  APISIX_CONTAINER="$APISIX_CONTAINER" \
  SHG_SCRIPT_PATH="$CRUNCH" bash "$CRUNCH" --since "${WT0}"); then
  ok "cleanup replay restored real signals"
else
  ko "cleanup replay failed"
fi

echo ""
echo "test_crunch_idempotency.sh: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi
exit 0
