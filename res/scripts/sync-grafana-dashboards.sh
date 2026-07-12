#!/bin/bash
# sync-grafana-dashboards.sh - Reload provisioned dashboards and verify defaults.
# Provisioned dashboards cannot be POSTed/deleted via API (allowUiUpdates: false).
# This script triggers a provisioning reload and checks time.from / refresh.
set -euo pipefail

GRAFANA_URL="${GRAFANA_URL:-http://localhost:3030}"
GRAFANA_AUTH="admin:${GRAFANA_ADMIN_PASSWORD:-admin}"

curl -sf -u "$GRAFANA_AUTH" -X POST \
    "$GRAFANA_URL/api/admin/provisioning/dashboards/reload" >/dev/null

for uid in gateway-cost-usage gateway-ops-health gateway-cost-leaderboard; do
    from=$(curl -sf -u "$GRAFANA_AUTH" "$GRAFANA_URL/api/dashboards/uid/$uid" \
        | jq -r '.dashboard.time.from')
    refresh=$(curl -sf -u "$GRAFANA_AUTH" "$GRAFANA_URL/api/dashboards/uid/$uid" \
        | jq -r '.dashboard.refresh')
    echo "$uid: time.from=$from refresh=$refresh"
    if [ "$from" != "now-7d" ] || [ "$refresh" != "5s" ]; then
        echo "ERROR: $uid defaults wrong (expected now-7d / 5s)" >&2
        exit 1
    fi
done