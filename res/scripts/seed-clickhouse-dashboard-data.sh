#!/usr/bin/env bash
set -euo pipefail

# seed-clickhouse-dashboard-data.sh
# Inserts deterministic request_log + usage_log rows for Grafana datasource
# proxy integration tests (T1-T5). Idempotent: removes prior seed rows first.
# --cleanup removes seed rows (request_log, usage_log, and cruncher-derived
# request_signals) so test data never leaks into live dashboards.
#
# Usage: seed-clickhouse-dashboard-data.sh [--clickhouse-url <url>] [--cleanup]

_SELF="${BASH_SOURCE[0]}"
case "$_SELF" in
    /proc/*) _SELF="${SHG_SCRIPT_PATH:-$_SELF}" ;;
esac
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# /proc/fd execution (test runners) leaves SHG_SCRIPT_PATH unset; use the
# caller's working directory when it is the repo root.
if [ ! -f "$REPO_ROOT/res/scripts/lib-sql.sh" ] && [ -f "$PWD/res/scripts/lib-sql.sh" ]; then
    REPO_ROOT="$PWD"
fi
export REPO_ROOT
# shellcheck source=/dev/null
source "$REPO_ROOT/res/scripts/lib-sql.sh" || exit 1

CH_URL="${CLICKHOUSE_URL:-http://localhost:8123}"
SEED_DB="llm_gateway"
SEED_MODEL="gw-integration-seed-model"
SEED_KEY="integration-seed-key"
SEED_RID_PREFIX="integration-seed-ds-proxy-"
SEED_EID_PREFIX="integration-seed-event-"
SEED_ROW_COUNT=150
CLEANUP_ONLY=0

# Authenticated ops access (REQ-SECURITY-HARDENING FR-1.3): no
# unauthenticated access.
CH_OPS_USER="${CH_OPS_USER:-ops_admin}"
: "${CH_OPS_PASSWORD:?CH_OPS_PASSWORD not set (source repo .env)}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --clickhouse-url) CH_URL="$2"; shift 2 ;;
        --cleanup) CLEANUP_ONLY=1; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

ch_query() {
    curl -sSf --max-time 30 -X POST --user "$CH_OPS_USER:$CH_OPS_PASSWORD" "$CH_URL/" --data-binary "$1"
}

ch_exec() {
    local out
    if ! out=$(ch_query "$1" 2>&1); then
        echo "[FAIL] ClickHouse query failed: $out" >&2
        return 1
    fi
    printf '%s' "$out"
}

echo "[INFO] Seeding ClickHouse dashboard integration data ($SEED_ROW_COUNT rows)..."

# Remove prior seed rows so counts stay deterministic across repeated runs.
# request_signals rows are derived by the usefulness cruncher from seeded
# request_log rows and must be removed too, or the seed model shows up on
# the model experience scorecard (it passes the >=100 requests gate).
cleanup_seed() {
    ch_exec "$(sql_render ops/seed-dashboard/cleanup-request-log.sql \
        DB="$SEED_DB" SEED_RID_PREFIX="$SEED_RID_PREFIX")" 1>&2
    ch_exec "$(sql_render ops/seed-dashboard/cleanup-usage-log.sql \
        DB="$SEED_DB" SEED_RID_PREFIX="$SEED_RID_PREFIX")" 1>&2
    ch_exec "$(sql_render ops/seed-dashboard/cleanup-request-signals.sql \
        DB="$SEED_DB" SEED_MODEL="$SEED_MODEL")" 1>&2
}

cleanup_seed

if [ "$CLEANUP_ONLY" -eq 1 ]; then
    echo "[INFO] Seed cleanup complete"
    exit 0
fi

# request_log: >100 rows, mixed status codes (200/401/404/500), populated model/key.
ch_exec "$(sql_render ops/seed-dashboard/insert-request-log.sql \
    DB="$SEED_DB" SEED_MODEL="$SEED_MODEL" SEED_KEY="$SEED_KEY" \
    SEED_RID_PREFIX="$SEED_RID_PREFIX" SEED_ROW_COUNT="$SEED_ROW_COUNT")" 1>&2

# usage_log: matching request_id rows for model filter + ASOF JOIN panels.
ch_exec "$(sql_render ops/seed-dashboard/insert-usage-log.sql \
    DB="$SEED_DB" SEED_MODEL="$SEED_MODEL" SEED_KEY="$SEED_KEY" \
    SEED_RID_PREFIX="$SEED_RID_PREFIX" SEED_EID_PREFIX="$SEED_EID_PREFIX" \
    SEED_ROW_COUNT="$SEED_ROW_COUNT")" 1>&2

seed_count=$(ch_exec "$(sql_render ops/seed-dashboard/count-request-log.sql \
    DB="$SEED_DB" SEED_RID_PREFIX="$SEED_RID_PREFIX")")
err_count=$(ch_exec "$(sql_render ops/seed-dashboard/count-errors.sql \
    DB="$SEED_DB" SEED_RID_PREFIX="$SEED_RID_PREFIX")")

if [ -z "${seed_count:-}" ] || [ "$seed_count" -lt 100 ]; then
    echo "[FAIL] Seed inserted only ${seed_count:-0} request_log rows (expected >=100)" >&2
    exit 1
fi
if [ -z "${err_count:-}" ] || [ "$err_count" -lt 1 ]; then
    echo "[FAIL] Seed has no 4xx/5xx rows (expected >=1)" >&2
    exit 1
fi

echo "[INFO] Seed complete: request_log=${seed_count} rows, errors=${err_count}"
