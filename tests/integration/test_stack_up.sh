#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/res/docker/docker-compose.yml"
DOCKERFILE="$REPO_ROOT/res/docker/Dockerfile.apisix"
IMAGE_TAG="workspace-gateway-apisix:local"

export PATH="$PATH:$REPO_ROOT/.venv/bin"

KEEP_STACK_UP="${KEEP_STACK_UP:-0}"

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

teardown() {
    if [ "${EXTERNAL_STACK:-0}" = "1" ]; then
        echo "[INFO] Stack was already running: leaving it up."
        echo "test_stack_up: $pass passed, $fail failed"
        return 0
    fi
    if [ "$KEEP_STACK_UP" = "1" ]; then
        return 0
    fi
    echo "[INFO] Tearing down stack..."
    podman-compose -f "$COMPOSE_FILE" down || echo "[WARN] teardown: podman-compose down failed (rc=$?)"
    if [ "$fail" -gt 0 ]; then
        echo "test_stack_up: $pass passed, $fail failed"
        exit 1
    fi
    echo "test_stack_up: $pass passed, $fail failed"
}
trap teardown EXIT

wait_for_url() {
    local url="$1"
    local name="$2"
    local max_attempts="${3:-30}"
    local attempt=0
    while [ "$attempt" -lt "$max_attempts" ]; do
        if curl -sf -o /dev/null "$url"; then
            record_pass "$name is ready ($url)"
            return 0
        fi
        attempt=$((attempt + 1))
        echo "  [$attempt/$max_attempts] $name not ready yet, retrying in 2s..."
        sleep 2
    done
    record_fail "$name not ready after $max_attempts attempts ($url)"
    return 1
}

wait_for_port() {
    local host="$1"
    local port="$2"
    local name="$3"
    local max_attempts="${4:-30}"
    local attempt=0
    while [ "$attempt" -lt "$max_attempts" ]; do
        if (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null; then
            exec 3>&- 3<&-
            record_pass "$name is listening on $host:$port"
            return 0
        fi
        attempt=$((attempt + 1))
        echo "  [$attempt/$max_attempts] $name not listening on $host:$port yet, retrying in 2s..."
        sleep 2
    done
    record_fail "$name not listening on $host:$port after $max_attempts attempts"
    return 1
}

step1_build() {
    if podman image exists "$IMAGE_TAG"; then
        record_pass "APISIX image already built ($IMAGE_TAG)"
        return 0
    fi
    echo "[INFO] Building APISIX image..."
    if podman build -t "$IMAGE_TAG" -f "$DOCKERFILE" "$REPO_ROOT"; then
        record_pass "Build APISIX image"
        return 0
    fi
    record_fail "Build APISIX image"
    return 1
}

step2_start() {
    echo "[INFO] Creating external network if needed..."
    podman network create dataops_default 2>&1 || echo "  (network may already exist)"
    echo "[INFO] Starting stack..."
    if podman-compose -f "$COMPOSE_FILE" up -d; then
        record_pass "Start stack"
        return 0
    fi
    record_fail "Start stack"
    return 1
}

step3_apisix() {
    local max_attempts=30
    local attempt=0
    while [ "$attempt" -lt "$max_attempts" ]; do
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:9080/" || echo "000")
        if [ "$code" != "000" ]; then
            record_pass "APISIX on port 9080 is ready (HTTP $code)"
            return 0
        fi
        attempt=$((attempt + 1))
        echo "  [$attempt/$max_attempts] APISIX not ready yet (curl returned 000), retrying in 2s..."
        sleep 2
    done
    record_fail "APISIX on port 9080 not ready after $max_attempts attempts (http://localhost:9080/)"
    return 1
}

step7_vector() {
    wait_for_port "localhost" "8080" "Vector" 30
}

step8_clickhouse() {
    wait_for_url "http://localhost:8123/ping" "ClickHouse on port 8123" 30
}

step8b_prometheus() {
    wait_for_url "http://localhost:9092/-/healthy" "Gateway Prometheus on port 9092" 30
}

step8c_grafana() {
    wait_for_url "http://localhost:3030/api/health" "Grafana on port 3030" 60
}

step9_tables() {
    local query="SELECT+count()+FROM+llm_gateway.request_log"
    local out
    local max_attempts=15
    local attempt=0
    while [ "$attempt" -lt "$max_attempts" ]; do
        if out=$(curl -sf "http://localhost:8123/?query=$query" 2>&1); then
            record_pass "ClickHouse request_log table exists (count=$out)"
            return 0
        fi
        attempt=$((attempt + 1))
        echo "  [$attempt/$max_attempts] ClickHouse table query failed: $out, retrying in 2s..."
        sleep 2
    done
    record_fail "ClickHouse request_log table query failed: $out"
    return 1
}

step10_teardown() {
    if [ "$KEEP_STACK_UP" = "1" ]; then
        record_pass "Tear down deferred (KEEP_STACK_UP=1)"
        return 0
    fi
    if podman-compose -f "$COMPOSE_FILE" down; then
        record_pass "Tear down stack"
        return 0
    fi
    record_fail "Tear down stack"
    return 1
}

main() {
    if [ "${EXTERNAL_STACK:-0}" = "1" ]; then
        echo "[INFO] Stack already running: skipping build/start, running health checks only."
    else
        step1_build
        step2_start
    fi
    step3_apisix
    step7_vector
    step8_clickhouse
    step8b_prometheus
    step8c_grafana
    step9_tables
    if [ "${EXTERNAL_STACK:-0}" != "1" ]; then
        step10_teardown
    else
        record_pass "Tear down skipped (external stack)"
    fi
}

main || true

if [ "$fail" -gt 0 ]; then
    exit 1
fi
exit 0
