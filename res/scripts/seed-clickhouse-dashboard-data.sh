#!/usr/bin/env bash
set -euo pipefail

# seed-clickhouse-dashboard-data.sh
# Inserts deterministic request_log + usage_log rows for Grafana datasource
# proxy integration tests (T1-T5). Idempotent: removes prior seed rows first.
#
# Usage: seed-clickhouse-dashboard-data.sh [--clickhouse-url <url>]

CH_URL="${CLICKHOUSE_URL:-http://localhost:8123}"
SEED_MODEL="gw-integration-seed-model"
SEED_KEY="integration-seed-key"
SEED_RID_PREFIX="integration-seed-ds-proxy-"
SEED_EID_PREFIX="integration-seed-event-"
SEED_ROW_COUNT=150

while [[ $# -gt 0 ]]; do
    case "$1" in
        --clickhouse-url) CH_URL="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

ch_query() {
    curl -sSf --max-time 30 -X POST "$CH_URL/" --data-binary "$1"
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
ch_exec "ALTER TABLE llm_gateway.request_log DELETE WHERE request_id LIKE '${SEED_RID_PREFIX}%'" 1>&2
ch_exec "ALTER TABLE llm_gateway.usage_log DELETE WHERE request_id LIKE '${SEED_RID_PREFIX}%'" 1>&2

# request_log: >100 rows, mixed status codes (200/401/404/500), populated model/key.
ch_exec "INSERT INTO llm_gateway.request_log (
    provider, method, uri, status, model, key_id, request_id,
    upstream_response_time_s, timestamp
)
SELECT
    'integration-seed' AS provider,
    'POST' AS method,
    '/v1/chat/completions' AS uri,
    multiIf(
        number % 10 = 0, 401,
        number % 7 = 0, 404,
        number % 13 = 0, 500,
        200
    ) AS status,
    '${SEED_MODEL}' AS model,
    '${SEED_KEY}' AS key_id,
    concat('${SEED_RID_PREFIX}', toString(number)) AS request_id,
    0.05 + (number % 10) * 0.01 AS upstream_response_time_s,
    now() - INTERVAL (number % 45) MINUTE AS timestamp
FROM numbers(${SEED_ROW_COUNT})" 1>&2

# usage_log: matching request_id rows for model filter + ASOF JOIN panels.
ch_exec "INSERT INTO llm_gateway.usage_log (
    event_id, request_id, model, key_id,
    prompt_tokens, completion_tokens, total_tokens, cost, timestamp
)
SELECT
    concat('${SEED_EID_PREFIX}', toString(number)) AS event_id,
    concat('${SEED_RID_PREFIX}', toString(number)) AS request_id,
    '${SEED_MODEL}' AS model,
    '${SEED_KEY}' AS key_id,
    100 AS prompt_tokens,
    50 AS completion_tokens,
    150 AS total_tokens,
    0.001 AS cost,
    now() - INTERVAL (number % 45) MINUTE AS timestamp
FROM numbers(${SEED_ROW_COUNT})" 1>&2

seed_count=$(ch_exec "SELECT count() FROM llm_gateway.request_log WHERE request_id LIKE '${SEED_RID_PREFIX}%' FORMAT TabSeparated")
err_count=$(ch_exec "SELECT countIf(status >= 400) FROM llm_gateway.request_log WHERE request_id LIKE '${SEED_RID_PREFIX}%' FORMAT TabSeparated")

if [ -z "${seed_count:-}" ] || [ "$seed_count" -lt 100 ]; then
    echo "[FAIL] Seed inserted only ${seed_count:-0} request_log rows (expected >=100)" >&2
    exit 1
fi
if [ -z "${err_count:-}" ] || [ "$err_count" -lt 1 ]; then
    echo "[FAIL] Seed has no 4xx/5xx rows (expected >=1)" >&2
    exit 1
fi

echo "[INFO] Seed complete: request_log=${seed_count} rows, errors=${err_count}"