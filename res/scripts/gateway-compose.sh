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
# /proc/fd execution (test runners) leaves SHG_SCRIPT_PATH unset; use
# to the caller's working directory when it is the repo root.
if [ ! -f "$REPO_ROOT/res/docker/docker-compose.yml" ] && [ -f "$PWD/res/docker/docker-compose.yml" ]; then
    REPO_ROOT="$PWD"
fi
COMPOSE_FILE="${COMPOSE_FILE:-$REPO_ROOT/res/docker/docker-compose.yml}"
COMPOSE_BIN="${COMPOSE_BIN:-$REPO_ROOT/.venv/bin/podman-compose}"
PODMAN_PATH="${PODMAN_PATH:?PODMAN_PATH must be set to the absolute podman binary path (the Makefile exports it)}"

usage() {
    printf 'Usage: %s {build|down|restart-service SERVICE|recreate-service SERVICE|logs [SERVICE]|migrate-up|migrate-status|migrate-force VERSION|exec SERVICE -- CMD [ARGS...]}\n' "$0" >&2
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
    "$COMPOSE_BIN" --podman-path "$PODMAN_PATH" -f "$COMPOSE_FILE" "$@"
}

case "${1:-}" in
    build)
        compose build
        ;;
    down)
        shift
        for arg in "$@"; do
            case "$arg" in
                -v|--volumes|-av|-va|--rmi-all)
                    echo "ERROR: refusing 'down' with volume/image removal: $arg (named volumes hold persistent Gateway data)" >&2
                    exit 1
                    ;;
            esac
        done
        compose down "$@"
        ;;
    restart-service)
        service="${2:-}"
        case "$service" in
            apisix|grafana|clickhouse|vector|openbao|prometheus|etcd) ;;
            *) echo "ERROR: invalid service: $service" >&2; usage; exit 2 ;;
        esac
        if [ "$service" = "apisix" ]; then
            PODMAN_PATH="$PODMAN_PATH" bash "$SCRIPT_DIR/drain-apisix.sh"
        fi
        # -a: drain-apisix.sh just stopped the container; podman ps without
        # -a lists only running containers, so the lookup would come up empty
        # and the service would never be started again.
        container_id="$("$PODMAN_PATH" ps -aq \
            --filter label=io.podman.compose.project=docker \
            --filter label=io.podman.compose.service="$service")"
        if [ -z "$container_id" ]; then
            echo "ERROR: running gateway container not found for service: $service" >&2
            exit 1
        fi
        timeout 60 "$PODMAN_PATH" restart --time 30 "$container_id"
        ;;
    recreate-service)
        # Recreate ONE service from the current compose file. Use this (not
        # gw-restart) to apply compose-level changes such as new networks:
        # `podman restart` cannot change a container's network attachments.
        # apisix is excluded: systemd owns it in the foreground.
        service="${2:-}"
        case "$service" in
            grafana|clickhouse|vector|openbao|prometheus|etcd) ;;
            *) echo "ERROR: recreate-service supports grafana|clickhouse|vector|openbao|prometheus|etcd (apisix is systemd-foreground; use gw-restart)" >&2; usage; exit 2 ;;
        esac
        compose up -d --force-recreate "$service"
        ;;
    exec)
        # In-container ops through the reviewed wrapper (debug ports are
        # unpublished; this is the sanctioned exec channel).
        service="${2:-}"
        [ "${3:-}" = "--" ] || { echo "ERROR: expected '--' before command" >&2; usage; exit 2; }
        shift 3
        case "$service" in
            apisix|grafana|clickhouse|vector|openbao|prometheus|etcd|migrate) ;;
            *) echo "ERROR: invalid service: $service" >&2; usage; exit 2 ;;
        esac
        container_id="$("$PODMAN_PATH" ps -q \
            --filter label=io.podman.compose.project=docker \
            --filter label=io.podman.compose.service="$service")"
        if [ -z "$container_id" ]; then
            echo "ERROR: running gateway container not found for service: $service" >&2
            exit 1
        fi
        exec "$PODMAN_PATH" exec -i "$container_id" "$@"
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
    migrate-force)
        version="${2:-}"
        if ! [[ "$version" =~ ^[0-9]+$ ]]; then
            echo "ERROR: migrate-force requires a numeric version (see migrate-status)" >&2
            usage
            exit 2
        fi
        compose --profile migration run --rm migrate force "$version"
        ;;
    *)
        usage
        exit 2
        ;;
esac
