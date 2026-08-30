#!/usr/bin/env bash
set -euo pipefail

# gateway-prod.sh: production/staging stack operations (REQ-GATEWAY-CORE FR-5).
# Mirrors the sibling-project prod convention: build a versioned image, run an
# isolated compose project (workspace-gateway-prod) on offset ports, verify
# health there BEFORE the dev stack is restarted onto the same code.
#
# Usage: gateway-prod.sh {build|start|stop|redeploy|verify|status|logs|logs-api|migrate ...}
# Env:  PODMAN_PATH (required), PROD_TAG (default localhost/workspace-gateway:0.1.0)

_SELF="${BASH_SOURCE[0]}"
case "$_SELF" in
    /proc/*) _SELF="${SHG_SCRIPT_PATH:-$_SELF}" ;;
esac
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
#When invoked through a /proc file descriptor the derived root is bogus
#(/proc); make always runs recipes from the repo root, so use cwd instead.
if [ ! -f "$REPO_ROOT/res/docker/docker-compose.prod.yml" ]; then
    REPO_ROOT="$(pwd)"
fi
if [ ! -f "$REPO_ROOT/res/docker/docker-compose.prod.yml" ]; then
    echo "ERROR: cannot locate repo root (invoked as $_SELF, cwd $(pwd))" >&2
    exit 1
fi
SCRIPT_DIR="$REPO_ROOT/res/scripts"
COMPOSE_FILE="$REPO_ROOT/res/docker/docker-compose.prod.yml"
COMPOSE_BIN="${COMPOSE_BIN:-$REPO_ROOT/.venv/bin/podman-compose}"
PODMAN_PATH="${PODMAN_PATH:?PODMAN_PATH must be set to the absolute podman binary path (the Makefile exports it)}"
PROJ="workspace-gateway-prod"
PROD_TAG="${PROD_TAG:-localhost/workspace-gateway:0.1.0}"

PROD_PORT=9081
ADMIN_PORT=9181
ADMIN_KEY="${ADMIN_KEY:-}"
PROD_TMP="$(mktemp)"
trap 'rm -f "$PROD_TMP"' EXIT

usage() {
    printf 'Usage: %s {build|start|stop|redeploy|verify|status|logs|logs-api}\n' "$0" >&2
}

if [ ! -x "$COMPOSE_BIN" ]; then
    echo "ERROR: podman-compose not executable: $COMPOSE_BIN" >&2
    exit 1
fi
if [ ! -f "$COMPOSE_FILE" ]; then
    echo "ERROR: compose file not found: $COMPOSE_FILE" >&2
    exit 1
fi

compose() {
    "$COMPOSE_BIN" --podman-path "$PODMAN_PATH" -p "$PROJ" -f "$COMPOSE_FILE" "$@"
}

load_admin_key() {
    if [ -z "$ADMIN_KEY" ] && [ -f "$REPO_ROOT/.env" ]; then
        ADMIN_KEY="$(grep -E '^ADMIN_KEY=' "$REPO_ROOT/.env" | cut -d= -f2-)"
    fi
    if [ -z "$ADMIN_KEY" ]; then
        echo "ERROR: ADMIN_KEY not set and not present in $REPO_ROOT/.env" >&2
        exit 1
    fi
}

wait_healthy() {
    local name="$1" attempts="${2:-60}"
    local i=0
    until curl -sS -m 5 -o "$PROD_TMP" "http://127.0.0.1:$PROD_PORT/"; do
        i=$((i + 1))
        if [ "$i" -ge "$attempts" ]; then
            echo "ERROR: $name not healthy after ${attempts} attempts" >&2
            return 1
        fi
        sleep 2
    done
    echo "$name healthy."
}

verify() {
    local failures=0
    echo "=== Prod verify ($PROJ) ==="

    echo "-- containers"
    "$PODMAN_PATH" ps --filter "label=io.podman.compose.project=$PROJ" --format '{{.Names}} {{.Status}}'
    for svc in gw-prod-apisix gw-prod-etcd gw-prod-openbao gw-prod-vector gw-prod-clickhouse; do
        if ! "$PODMAN_PATH" ps --format '{{.Names}}' | grep -qx "$svc"; then
            echo "FAIL: container missing: $svc"
            failures=$((failures + 1))
        fi
    done

    echo "-- gateway root"
    local root_code
    root_code=$(curl -sS -m 15 -o "$PROD_TMP" -w '%{http_code}' "http://127.0.0.1:$PROD_PORT/")
    echo "root status: $root_code"
    if [ "$root_code" = "000" ]; then
        echo "FAIL: gateway not answering on $PROD_PORT"
        failures=$((failures + 1))
    else
        echo "OK (404 expected: no root route)"
    fi

    echo "-- provider catalog"
    local sync
    if ! sync=$(curl -fsS -m 60 -X POST "http://127.0.0.1:$PROD_PORT/gateway/providers/sync"); then
        sync='{"ok":false}'
    fi
    echo "$sync"
    if ! echo "$sync" | grep -q '"ok":true'; then
        echo "FAIL: provider sync did not succeed"
        failures=$((failures + 1))
    fi
    local count
    count=$(curl -fsS "http://127.0.0.1:$PROD_PORT/gateway/providers" | jq 'length')
    echo "providers: $count"
    if [ "${count:-0}" -lt 1 ]; then
        echo "FAIL: no providers served"
        failures=$((failures + 1))
    fi

    echo "-- oauth device flow endpoints (kimi)"
    local device
    if ! device=$(curl -sS -m 30 -X POST "http://127.0.0.1:$PROD_PORT/kimi/auth/device?session=prod-verify" \
        -H "Accept: application/json"); then
        device='{"error":"request failed"}'
    fi
    if [ -n "$(echo "$device" | jq -r '.user_code // empty')" ]; then
        echo "OK: device flow issued a user code"
    else
        echo "FAIL: device flow failed: $device"
        failures=$((failures + 1))
    fi

    echo "-- key-auth rejection"
    local code
    code=$(curl -sS -o /dev/null -w '%{http_code}' -m 15 \
        "http://127.0.0.1:$PROD_PORT/kimi/v1/chat/completions" \
        -H 'Content-Type: application/json' \
        -d '{"model":"kimi-k2.7-code","messages":[{"role":"user","content":"hi"}]}')
    if [ "$code" = "401" ]; then
        echo "OK: unauthenticated relay rejected with 401"
    else
        echo "FAIL: expected 401, got $code"
        failures=$((failures + 1))
    fi

    echo "-- usage logging (vector -> clickhouse)"
    sleep 2
    local rows
    if ! rows=$(curl -sS -m 10 "http://127.0.0.1:8124/" \
        --data-binary "SELECT count() FROM llm_gateway.request_log FORMAT TSV"); then
        rows="-1"
    fi
    echo "request_log rows: $rows"
    if [ "${rows:-x}" = "-1" ]; then
        echo "WARN: clickhouse query failed on prod port 8124"
    fi

    echo "-- routes seeded"
    load_admin_key
    local routes
    routes=$(curl -fsS -H "X-API-KEY: $ADMIN_KEY" \
        "http://127.0.0.1:$ADMIN_PORT/apisix/admin/routes" | jq '.total')
    echo "routes: $routes"
    if [ "${routes:-0}" -lt 1 ]; then
        echo "FAIL: no routes seeded in prod etcd"
        failures=$((failures + 1))
    fi

    echo "=== Prod verify: $failures failure(s) ==="
    [ "$failures" -eq 0 ]
}

case "${1:-}" in
    build)
        echo "Building $PROD_TAG (context: $REPO_ROOT)"
        "$PODMAN_PATH" build -f "$REPO_ROOT/res/docker/Dockerfile.apisix" \
            -t "$PROD_TAG" "$REPO_ROOT"
        ;;
    start)
        load_admin_key
        echo "Starting prod stack ($PROJ)"
        compose up -d etcd openbao clickhouse vector
        echo "Waiting for dependencies..."
        sleep 5
        compose --profile migration run --rm migrate up
        #--force-recreate: podman-compose reuses existing containers even when
        #the image tag was rebuilt; prod must always run the current image.
        compose up -d --force-recreate apisix
        wait_healthy "gw-prod-apisix"
        echo "Seeding routes from conf/apisix.yaml (admin on $ADMIN_PORT)"
        ADMIN_KEY="$ADMIN_KEY" APISIX_YAML="$REPO_ROOT/conf/apisix.yaml" \
            bash "$SCRIPT_DIR/seed-routes.sh" \
            --admin-key "$ADMIN_KEY" \
            --admin-url "http://127.0.0.1:$ADMIN_PORT"
        echo "Prod stack started on http://127.0.0.1:$PROD_PORT"
        ;;
    stop)
        compose stop -t 30
        ;;
    redeploy)
        "$0" stop
        "$0" start
        "$0" verify
        ;;
    verify)
        verify
        ;;
    status)
        compose ps
        ;;
    migrate)
        shift
        compose --profile migration run --rm migrate "${@:-up}"
        ;;
    logs)
        if [ -n "${2:-}" ]; then
            compose logs --tail=200 "$2"
        else
            compose logs --tail=200
        fi
        ;;
    logs-api)
        "$PODMAN_PATH" logs --tail=200 gw-prod-apisix
        ;;
    *)
        usage
        exit 2
        ;;
esac
