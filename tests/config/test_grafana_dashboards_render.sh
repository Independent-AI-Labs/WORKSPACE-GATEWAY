#!/bin/bash
set -euo pipefail

# tests/config/test_grafana_dashboards_render.sh
# Drift guard for the Grafana SQL render (SPEC-SQL-STRUCTURE section 3):
# sources under conf/grafana/{dashboards,provisioning} reference conf/sql via
# {{sql:<path>}}, and the committed conf/grafana/rendered/ tree Grafana mounts
# is exactly what res/scripts/render-grafana-dashboards.sh produces. Does NOT
# require a running stack.

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
    _SELF="$SHG_SCRIPT_PATH"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC_DASH="$REPO_ROOT/conf/grafana/dashboards"
REN_DASH="$REPO_ROOT/conf/grafana/rendered/dashboards"
REN_PROV="$REPO_ROOT/conf/grafana/rendered/provisioning"
RENDERER="$REPO_ROOT/res/scripts/render_grafana_dashboards.py"

pass=0
fail=0

ok() { echo "[PASS] $1"; pass=$((pass + 1)); }
ko() { echo "[FAIL] $1"; fail=$((fail + 1)); }
assert_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else ko "$1 -- expected [$2], actual [$3]"; fi
}

assert_eq "renderer exists" "yes" "$(if [ -f "$RENDERER" ]; then printf yes; else printf no; fi)"
assert_eq "rendered dashboards dir exists" "yes" "$(if [ -d "$REN_DASH" ]; then printf yes; else printf no; fi)"

# Every source dashboard references conf/sql, every rendered one has real SQL.
SRC_NO_REF=0
REN_STILL_REF=0
for f in "$SRC_DASH"/*.json; do
    if grep -q '{{sql:' "$f"; then :; else SRC_NO_REF=$((SRC_NO_REF + 1)); fi
done
for f in "$REN_DASH"/*.json; do
    if grep -q '{{sql:' "$f"; then REN_STILL_REF=$((REN_STILL_REF + 1)); fi
done
assert_eq "all source dashboards reference {{sql:...}}" "0" "$SRC_NO_REF"
assert_eq "no rendered dashboard retains {{sql:...}}" "0" "$REN_STILL_REF"

# Rendered dashboards are valid JSON with expanded ClickHouse SQL.
REN_CH_NO_SQL=0
for f in "$REN_DASH"/*.json; do
    n=$(jq '[.panels[]|select(.datasource.uid=="clickhouse")|.targets[]|select((.rawSql//null)==null or (.rawSql|test("\\{\\{sql:")))]|length' "$f")
    REN_CH_NO_SQL=$((REN_CH_NO_SQL + n))
done
assert_eq "rendered ClickHouse targets all carry expanded rawSql" "0" "$REN_CH_NO_SQL"

# Alerting render is expanded.
ALERT="$REN_PROV/alerting/storage-growth.yaml"
if [ -f "$ALERT" ] && ! grep -q '{{sql:' "$ALERT" && grep -q 'rawSql:.*system.parts' "$ALERT"; then
    ok "rendered alerting rawSql is expanded"
else
    ko "rendered alerting rawSql is expanded"
fi

# Drift: regenerate into a temp dir and compare byte-for-byte.
if uv run python "$RENDERER" --check 1>&2; then
    ok "committed rendered tree matches a fresh render"
else
    ko "committed rendered tree is stale"
fi

echo ""
echo "test_grafana_dashboards_render.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
