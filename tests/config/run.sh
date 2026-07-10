#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass=0
fail=0

for test_script in test_apisix_yaml.sh test_apisix_yaml_render.sh test_config_yaml.sh test_compose.sh test_dockerfile.sh test_patterns_json.sh test_clickhouse_sql.sh test_vector_toml.sh test_grafana_provisioning.sh test_dashboard_cost_usage.sh test_dashboard_ops_health.sh test_dashboard_cost_leaderboard.sh test_migrations.sh test_sync_opencode_models.sh; do
    echo "=== Running $test_script ==="
    if bash "$SCRIPT_DIR/$test_script"; then
        echo "[PASS] $test_script"
        pass=$((pass + 1))
    else
        echo "[FAIL] $test_script"
        fail=$((fail + 1))
    fi
done

echo ""
echo "Config tests: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi