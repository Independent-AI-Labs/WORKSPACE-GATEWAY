#!/bin/bash
# sync-grafana-dashboards.sh - Reload provisioned dashboards and verify defaults.
# Provisioned dashboards cannot be POSTed/deleted via API (allowUiUpdates: false).
# This script triggers a provisioning reload and checks time.from / refresh on
# every rendered dashboard, so the checked set never drifts from the files.
set -euo pipefail

_SELF="${BASH_SOURCE[0]}"
case "$_SELF" in
    /proc/*) _SELF="${SHG_SCRIPT_PATH:-$_SELF}" ;;
esac
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
if [ ! -d "$REPO_ROOT/conf/grafana/rendered/dashboards" ] \
    && [ -d "$PWD/conf/grafana/rendered/dashboards" ]; then
    REPO_ROOT="$PWD"
fi

if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    if ! source "$REPO_ROOT/.env"; then
        echo "ERROR: could not source $REPO_ROOT/.env" >&2
        exit 1
    fi
    set +a
fi

GRAFANA_URL="${GRAFANA_URL:-http://localhost:3030}"
# Grafana admin login uses the rotated secret (RUNBOOK-SECRETS / FR-10.1);
# never the public `admin` default.
GRAFANA_AUTH="admin:${GRAFANA_ADMIN_PASSWORD:?GRAFANA_ADMIN_PASSWORD not set (source repo .env)}"

curl -sSf -u "$GRAFANA_AUTH" -X POST \
    "$GRAFANA_URL/api/admin/provisioning/dashboards/reload" 1>&2
echo

DASH_DIR="$REPO_ROOT/conf/grafana/rendered/dashboards"
for f in "$DASH_DIR"/*.json; do
    uid=$(jq -r '.uid' "$f")
    [ -n "$uid" ] && [ "$uid" != "null" ] || continue
    from=$(curl -sSf -u "$GRAFANA_AUTH" "$GRAFANA_URL/api/dashboards/uid/$uid" \
        | jq -r '.dashboard.time.from')
    refresh=$(curl -sSf -u "$GRAFANA_AUTH" "$GRAFANA_URL/api/dashboards/uid/$uid" \
        | jq -r '.dashboard.refresh')
    echo "$uid: time.from=$from refresh=$refresh"
    if [ "$from" != "now-90d" ] || [ "$refresh" != "5s" ]; then
        echo "ERROR: $uid defaults wrong (expected now-90d / 5s)" >&2
        exit 1
    fi
done
