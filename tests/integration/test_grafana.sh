#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass=0
fail=0

record_pass() {
    echo "[PASS] $1"
    pass=$((pass + 1))
}

record_fail() {
    echo "[FAIL] $1"
    fail=$((fail + 1))
}

wait_for_url() {
    local url="$1"
    local name="$2"
    local max_attempts="${3:-30}"
    local attempt=0
    while [ "$attempt" -lt "$max_attempts" ]; do
        if curl -sf -o /dev/null "$url" 2>/dev/null; then
            record_pass "$name is ready ($url)"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 3
    done
    record_fail "$name not ready after $max_attempts attempts ($url)"
    return 1
}

echo "=== Grafana Integration Tests ==="
echo ""

# ── 1. Prometheus health ──────────────────────────────────────────────

wait_for_url "http://localhost:9092/-/healthy" "Gateway Prometheus on port 9092" 30

# ── 2. Prometheus scraping APISIX ─────────────────────────────────────

PROM_TARGETS=$(curl -s http://localhost:9092/api/v1/targets 2>/dev/null || echo "")
if [ -z "$PROM_TARGETS" ]; then
    record_fail "Prometheus targets API returned empty"
else
    APISIX_HEALTH=$(echo "$PROM_TARGETS" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for t in d['data']['activeTargets']:
    if t['scrapePool'] == 'gateway-apisix':
        print(t['health'])
        break
else:
    print('not_found')
" 2>/dev/null || echo "parse_error")

    if [ "$APISIX_HEALTH" = "up" ]; then
        record_pass "Prometheus is scraping APISIX (target up)"
    else
        record_fail "Prometheus APISIX target health: $APISIX_HEALTH"
    fi
fi

# ── 3. Grafana health ─────────────────────────────────────────────────

wait_for_url "http://localhost:3030/api/health" "Grafana on port 3030" 60

GRAFANA_VERSION=$(curl -s http://localhost:3030/api/health 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('version','unknown'))" 2>/dev/null || echo "unknown")
if [ "$GRAFANA_VERSION" = "12.0.0" ]; then
    record_pass "Grafana version is 12.0.0"
else
    record_fail "Grafana version mismatch: expected 12.0.0, got $GRAFANA_VERSION"
fi

# ── 4. Grafana datasources provisioned ────────────────────────────────

DATASOURCES=$(curl -s http://admin:admin@localhost:3030/api/datasources 2>/dev/null || echo "[]")
DS_COUNT=$(echo "$DATASOURCES" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

if [ "$DS_COUNT" = "2" ]; then
    record_pass "Grafana has 2 datasources provisioned"
else
    record_fail "Grafana datasource count: expected 2, got $DS_COUNT"
fi

DS_NAMES=$(echo "$DATASOURCES" | python3 -c "
import json,sys
d = json.load(sys.stdin)
names = sorted([ds['name'] for ds in d])
print(','.join(names))
" 2>/dev/null || echo "")

if [ "$DS_NAMES" = "ClickHouse,Prometheus" ]; then
    record_pass "Grafana has Prometheus and ClickHouse datasources"
else
    record_fail "Grafana datasource names: expected ClickHouse,Prometheus, got $DS_NAMES"
fi

# ── 5. Dashboard provisioned ──────────────────────────────────────────

DASHBOARDS=$(curl -s http://admin:admin@localhost:3030/api/search 2>/dev/null || echo "[]")
HAS_OVERVIEW=$(echo "$DASHBOARDS" | python3 -c "
import json,sys
d = json.load(sys.stdin)
found = any(item.get('title') == 'Gateway Overview' for item in d)
print('true' if found else 'false')
" 2>/dev/null || echo "false")

if [ "$HAS_OVERVIEW" = "true" ]; then
    record_pass "Gateway Overview dashboard is provisioned"
else
    record_fail "Gateway Overview dashboard not found in Grafana"
fi

# ── 6. Container names do not conflict ────────────────────────────────

if podman ps --format '{{.Names}}' 2>/dev/null | grep -q '^gw-grafana$'; then
    record_pass "Grafana container name is gw-grafana (no conflict)"
else
    record_fail "Grafana container name gw-grafana not found"
fi

if podman ps --format '{{.Names}}' 2>/dev/null | grep -q '^gw-prometheus$'; then
    record_pass "Prometheus container name is gw-prometheus (no conflict)"
else
    record_fail "Prometheus container name gw-prometheus not found"
fi

if podman ps --format '{{.Names}}' 2>/dev/null | grep -q '^ami-prometheus$'; then
    record_pass "DATAOPS Prometheus (ami-prometheus) still running separately"
else
    record_pass "DATAOPS Prometheus not running (no conflict possible)"
fi

echo ""
echo "Grafana integration tests: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi
exit 0
