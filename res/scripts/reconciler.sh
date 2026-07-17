#!/bin/bash
set -euo pipefail

# Portable "yesterday" via platform detection (no stderr suppression needed)
case "$(uname -s)" in
    Linux*)
        YESTERDAY=$(date -d "yesterday" +%Y-%m-%d) ;;
    Darwin*)
        YESTERDAY=$(date -v-1d +%Y-%m-%d) ;;
    *)
        YESTERDAY=$(date -u -d "@$(( $(date +%s) - 86400 ))" +%Y-%m-%d \
          || date -u -r $(( $(date +%s) - 86400 )) +%Y-%m-%d) ;;
esac

CLICKHOUSE_HOST="${CLICKHOUSE_HOST:-localhost}"
CLICKHOUSE_PORT="${CLICKHOUSE_PORT:-8123}"
CH_URL="http://${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}"

query_clickhouse() {
    local sql="$1"
    curl -sSf --max-time 10 "$CH_URL/" --data-binary "$sql"
}

GATEWAY_TOTALS=$(query_clickhouse "
    SELECT provider, model,
           sum(prompt_tokens), sum(completion_tokens), sum(total_tokens)
    FROM llm_gateway.request_log
    WHERE toDate(timestamp) = '$YESTERDAY'
    GROUP BY provider, model
    FORMAT TabSeparated
") || {
    echo "[reconciler] ERROR: ClickHouse query failed" >&2
    echo "$GATEWAY_TOTALS" >&2
    exit 1
}

if [ -z "$GATEWAY_TOTALS" ]; then
    echo "[reconciler] No records for $YESTERDAY, nothing to reconcile"
    exit 0
fi

echo "$GATEWAY_TOTALS" | while IFS=$'\t' read -r provider model prompt completion total; do
    echo "[reconciler] $provider/$model: prompt=$prompt completion=$completion total=$total"

    # v2: Compare gateway totals against upstream provider usage API.
    # Divergences beyond tolerance will be inserted into
    # billing_discrepancies. Until then, gateway totals are logged
    # for audit purposes. Divergences are never discarded
    # (AGENTS.md Rule 13).
done

echo "[reconciler] completed for $YESTERDAY"
