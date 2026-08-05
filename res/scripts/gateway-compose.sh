#!/usr/bin/env bash
set -euo pipefail

# Keep Python-backed podman-compose invocation in script context. The workspace
# shell guard intentionally rejects interpreter-like commands embedded in make
# recipe text.
_SELF="${BASH_SOURCE[0]}"
case "$_SELF" in
    /proc/*) _SELF="${SHG_SCRIPT_PATH:-$_SELF}" ;;
esac
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-$REPO_ROOT/res/docker/docker-compose.yml}"
COMPOSE_BIN="${COMPOSE_BIN:-$REPO_ROOT/.venv/bin/podman-compose}"

usage() {
    printf 'Usage: %s {build|down|clean|restart-service SERVICE|logs [SERVICE]|migrate-up|migrate-status}\n' "$0" >&2
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
    "$COMPOSE_BIN" -f "$COMPOSE_FILE" "$@"
}

case "${1:-}" in
    build)
        compose build
        ;;
    down)
        compose down
        ;;
    clean)
        compose down -v
        ;;
    restart-service)
        service="${2:-}"
        case "$service" in
            apisix|grafana|clickhouse|vector|openbao|prometheus) ;;
            *) echo "ERROR: invalid service: $service" >&2; usage; exit 2 ;;
        esac
        if [ "$service" = "apisix" ]; then
            bash "$SCRIPT_DIR/drain-apisix.sh"
        fi
        container_id="$(podman ps -q \
            --filter label=io.podman.compose.project=docker \
            --filter label=io.podman.compose.service="$service")"
        if [ -z "$container_id" ]; then
            echo "ERROR: running gateway container not found for service: $service" >&2
            exit 1
        fi
        timeout 60 podman restart --time 30 "$container_id"
        ;;
    logs)
        if [ -n "${2:-}" ]; then
            compose logs --tail=200 "$2"
        else
            compose logs --tail=200
        fi
        ;;
    migrate-up)
        compose --profile migration run --rm migrate up
        ;;
    migrate-status)
        compose --profile migration run --rm migrate version
        ;;
    *)
        usage
        exit 2
        ;;
esac
