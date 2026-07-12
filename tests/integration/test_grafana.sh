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
    APISIX_HEALTH=$(echo "$PROM_TARGETS" | jq -r '[.data.activeTargets[] | select(.scrapePool == "gateway-apisix")][0].health // "not_found"' 2>/dev/null || echo "parse_error")

    if [ "$APISIX_HEALTH" = "up" ]; then
        record_pass "Prometheus is scraping APISIX (target up)"
    else
        record_fail "Prometheus APISIX target health: $APISIX_HEALTH"
    fi
fi

# ── 3. Grafana health ─────────────────────────────────────────────────

wait_for_url "http://localhost:3030/api/health" "Grafana on port 3030" 60

GRAFANA_VERSION=$(curl -s http://localhost:3030/api/health 2>/dev/null | jq -r '.version // "unknown"' 2>/dev/null || echo "unknown")
# Min version 12.4.0 (time-range pan/zoom GA). Use awk semver compare.
if awk -v a="$GRAFANA_VERSION" -v b="12.4.0" 'BEGIN{n=split(a,va,".");m=split(b,vb,".");for(i=1;i<=(n>m?n:m);i++){x=va[i]+0;y=vb[i]+0;if(x>y)exit 0;if(x<y)exit 1}exit 0}' 2>/dev/null; then
    record_pass "Grafana version >= 12.4.0 (got $GRAFANA_VERSION)"
else
    record_fail "Grafana version too old: expected >= 12.4.0, got $GRAFANA_VERSION"
fi

# ── 4. Grafana datasources provisioned ────────────────────────────────

DATASOURCES=$(curl -s http://admin:admin@localhost:3030/api/datasources 2>/dev/null || echo "[]")
DS_COUNT=$(echo "$DATASOURCES" | jq 'length' 2>/dev/null || echo "0")

if [ "$DS_COUNT" = "2" ]; then
    record_pass "Grafana has 2 datasources provisioned"
else
    record_fail "Grafana datasource count: expected 2, got $DS_COUNT"
fi

DS_NAMES=$(echo "$DATASOURCES" | jq -r '[.[].name] | sort | join(",")' 2>/dev/null || echo "")

if [ "$DS_NAMES" = "ClickHouse,Prometheus" ]; then
    record_pass "Grafana has Prometheus and ClickHouse datasources"
else
    record_fail "Grafana datasource names: expected ClickHouse,Prometheus, got $DS_NAMES"
fi

# ── 5. Dashboards provisioned (3 split dashboards) ───────────────────

DASHBOARDS=$(curl -s http://admin:admin@localhost:3030/api/search 2>/dev/null || echo "[]")

for dash_info in "Gateway Cost & Usage|gateway-cost-usage" \
                 "Gateway Operations & Health|gateway-ops-health" \
                 "Gateway Cost Leaderboard|gateway-cost-leaderboard"; do
    dash_title="${dash_info%%|*}"
    dash_uid="${dash_info##*|}"
    has_dash=$(echo "$DASHBOARDS" | jq --arg t "$dash_title" '[.[] | select(.title == $t)] | length > 0' 2>/dev/null || echo "false")
    if [ "$has_dash" = "true" ]; then
        record_pass "$dash_title dashboard is provisioned"
    else
        record_fail "$dash_title dashboard not found in Grafana"
    fi
done

# ── 5b. Dashboard defaults (7d lookback, 5s refresh) ───────────────────

for dash_uid in gateway-cost-usage gateway-ops-health gateway-cost-leaderboard; do
    dash_json=$(curl -s "http://admin:admin@localhost:3030/api/dashboards/uid/$dash_uid" 2>/dev/null || echo "{}")
    dash_from=$(echo "$dash_json" | jq -r '.dashboard.time.from // "missing"' 2>/dev/null || echo "parse_error")
    dash_refresh=$(echo "$dash_json" | jq -r '.dashboard.refresh // "missing"' 2>/dev/null || echo "parse_error")
    if [ "$dash_from" = "now-7d" ] && [ "$dash_refresh" = "5s" ]; then
        record_pass "$dash_uid defaults: now-7d / 5s"
    else
        record_fail "$dash_uid defaults: expected now-7d / 5s, got $dash_from / $dash_refresh"
    fi
done

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
