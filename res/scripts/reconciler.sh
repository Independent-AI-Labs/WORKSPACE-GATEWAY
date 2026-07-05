#!/bin/bash
set -euo pipefail

YESTERDAY=$(date -d "yesterday" +%Y-%m-%d)
TOLERANCE="0.01"

CLICKHOUSE_HOST="${CLICKHOUSE_HOST:-clickhouse}"
CLICKHOUSE_PORT="${CLICKHOUSE_PORT:-8123}"

GATEWAY_TOTALS=$(clickhouse-client \
  --host "$CLICKHOUSE_HOST" \
  --port "$CLICKHOUSE_PORT" \
  --query "
    SELECT provider, model_name,
           sum(prompt_tokens), sum(completion_tokens), sum(total_tokens)
    FROM llm_gateway.billing_ledger
    WHERE toDate(timestamp) = '$YESTERDAY' AND success = 1
    GROUP BY provider, model_name
    FORMAT TabSeparated
  " 2>&1) || {
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

    # Compare against upstream provider billing API.
    # Divergences beyond tolerance are inserted into billing_discrepancies.
    # Divergences are never discarded (AGENTS.md Rule 13).
    #
    # TODO: implement per-provider usage API queries when API keys are
    # provisioned. For now, the gateway totals are logged for audit.
done

echo "[reconciler] completed for $YESTERDAY"
