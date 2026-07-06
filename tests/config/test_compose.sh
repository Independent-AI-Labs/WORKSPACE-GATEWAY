#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass=0
fail=0

assert_eq() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "[PASS] $desc"
        pass=$((pass + 1))
    else
        echo "[FAIL] $desc -- expected: $expected, actual: $actual"
        fail=$((fail + 1))
    fi
}

summary() {
    echo ""
    echo "test_compose.sh: $pass passed, $fail failed"
    if [ "$fail" -gt 0 ]; then
        exit 1
    fi
}

COMPOSE_YAML="$REPO_ROOT/res/docker/docker-compose.yml"

JSON_DATA=$(python3 -c "
import yaml, json
with open('$COMPOSE_YAML') as f:
    data = yaml.safe_load(f)
print(json.dumps(data))
")
ret=$?
if [ "$ret" -ne 0 ]; then
    echo "[FAIL] Valid YAML"
    fail=$((fail + 1))
    summary
fi

assert_eq "Valid YAML" "ok" "ok"

HAS_APISIX=$(echo "$JSON_DATA" | jq '.services | has("apisix")')
assert_eq "Has apisix service" "true" "$HAS_APISIX"

HAS_CLICKHOUSE=$(echo "$JSON_DATA" | jq '.services | has("clickhouse")')
assert_eq "Has clickhouse service" "true" "$HAS_CLICKHOUSE"

HAS_VECTOR=$(echo "$JSON_DATA" | jq '.services | has("vector")')
assert_eq "Has vector service" "true" "$HAS_VECTOR"

APISIX_PORT_9080=$(echo "$JSON_DATA" | jq '[.services.apisix.ports[] | select(. == "9080:9080")] | length')
assert_eq "APISIX exposes port 9080" "1" "$APISIX_PORT_9080"

APISIX_PORT_9100=$(echo "$JSON_DATA" | jq '[.services.apisix.ports[] | select(. == "9100:9100")] | length')
assert_eq "APISIX exposes port 9100 for prometheus" "1" "$APISIX_PORT_9100"

APISIX_MOUNTS=$(echo "$JSON_DATA" | jq -r '.services.apisix.volumes[]')
HAS_APISIX_YAML=$(echo "$APISIX_MOUNTS" | grep -c "apisix.yaml" || true)
assert_eq "APISIX mounts apisix.yaml" "1" "$HAS_APISIX_YAML"

HAS_REDACT_PATTERNS=$(echo "$APISIX_MOUNTS" | grep -c "redact-patterns.json" || true)
assert_eq "APISIX mounts redact-patterns.json" "1" "$HAS_REDACT_PATTERNS"

CLICKHOUSE_MOUNTS=$(echo "$JSON_DATA" | jq -r '.services.clickhouse.volumes[]')
HAS_INIT_SQL=$(echo "$CLICKHOUSE_MOUNTS" | grep -c "clickhouse-init.sql" || true)
assert_eq "ClickHouse mounts clickhouse-init.sql" "1" "$HAS_INIT_SQL"

VECTOR_MOUNTS=$(echo "$JSON_DATA" | jq -r '.services.vector.volumes[]')
HAS_VECTOR_TOML=$(echo "$VECTOR_MOUNTS" | grep -c "vector.toml" || true)
assert_eq "Vector mounts vector.toml" "1" "$HAS_VECTOR_TOML"

VECTOR_PORT_8080=$(echo "$JSON_DATA" | jq '[.services.vector.ports[] | select(. == "8080:8080")] | length')
assert_eq "Vector exposes port 8080" "1" "$VECTOR_PORT_8080"

VECTOR_CMD=$(echo "$JSON_DATA" | jq -r '[.services.vector.command[] | select(. == "/etc/vector/vector.toml")] | length')
assert_eq "Vector command specifies vector.toml config" "1" "$VECTOR_CMD"

HAS_GATEWAY=$(echo "$JSON_DATA" | jq '.networks | has("gateway")')
assert_eq "Networks has gateway" "true" "$HAS_GATEWAY"

HAS_DATAOPS=$(echo "$JSON_DATA" | jq '.networks | has("dataops")')
assert_eq "Networks has dataops" "true" "$HAS_DATAOPS"

APISIX_ENV_FILE=$(echo "$JSON_DATA" | jq -r '.services.apisix.env_file[]')
HAS_ENV_FILE=$(echo "$APISIX_ENV_FILE" | grep -c "\.env" || true)
assert_eq "APISIX has env_file pointing to .env" "1" "$HAS_ENV_FILE"

summary