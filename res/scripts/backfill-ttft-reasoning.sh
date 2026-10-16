#!/bin/bash
set -euo pipefail

# backfill-ttft-reasoning.sh - correct ttft_content_ms for Anthropic
# extended-thinking streams recorded before the content-detection fix.
#
# Anthropic reports no separate reasoning-token count, so completion_tokens
# (output_tokens) includes thinking tokens. The old sse_usage_lib only counted
# content_block_delta.delta.text as "content", so ttft_content_ms was stamped
# at the first *visible answer* token (after thinking) or never stamped,
# collapsing the decode window to the answer tail and inflating tok/s by an
# order of magnitude. New traffic is fixed in the plugin; this repairs the
# stored rows by replacing the stamp with ttft_first_byte_ms (the
# message_start frame, the closest stored proxy for the first generated
# token). Idempotent: only rows still missing or later than the first-byte
# stamp are touched.
#
# Usage: res/scripts/backfill-ttft-reasoning.sh [--apply] [--database NAME]
#   --apply          perform the mutation (default: dry-run, print the count)
#   --database NAME  schema (default llm_gateway)
# Env: CLICKHOUSE_HOST (default localhost), CLICKHOUSE_PORT (default 8123),
#      CH_OPS_USER (default ops_admin) / CH_OPS_PASSWORD.

CLICKHOUSE_HOST="${CLICKHOUSE_HOST:-localhost}"
CLICKHOUSE_PORT="${CLICKHOUSE_PORT:-8123}"
CH_URL="http://${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}"
DATABASE="llm_gateway"
APPLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply) APPLY=true; shift ;;
        --database) DATABASE="$2"; shift 2 ;;
        *) echo "backfill-ttft-reasoning: unknown argument: $1" >&2; exit 1 ;;
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

ch() { ch_exec "$1" 300; }

echo "[ttft-backfill] ClickHouse: $CH_URL (db=$DATABASE, apply=$APPLY)"
AFFECTED="$(ch "$(sql_render ops/backfill-ttft-reasoning/affected-count.sql DB="$DATABASE")")"
echo "[ttft-backfill] rows to correct: $AFFECTED"
if [ "$AFFECTED" = "0" ]; then
    echo "[ttft-backfill] nothing to do."
    exit 0
fi

if ! $APPLY; then
    echo "[ttft-backfill] DRY RUN - no data written. Re-run with --apply."
    exit 0
fi

echo "[ttft-backfill] applying mutation (mutations_sync=1, this blocks until done)..."
ch "$(sql_render ops/backfill-ttft-reasoning/update-ttft.sql DB="$DATABASE")"
echo "[ttft-backfill] applied."

echo "[ttft-backfill] verification (remaining / corrected):"
ch "$(sql_render ops/backfill-ttft-reasoning/verify.sql DB="$DATABASE")"
echo "[ttft-backfill] done."