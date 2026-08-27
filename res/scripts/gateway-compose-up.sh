#!/bin/bash
set -euo pipefail

# podman-compose starts independent services concurrently. That is unsafe in
# this rootless setup: APISIX can ask Podman to attach to a dependency before
# Podman has finished creating that dependency. Bootstrap each service under a
# process lock, then keep APISIX in the foreground for systemd.

LOCK_DIR="${XDG_RUNTIME_DIR:-/tmp}"
LOCK_FILE="$LOCK_DIR/workspace-gateway-compose.lock"

# Keep the lock in flock's process so container helpers cannot inherit it.
if [ "${1:-}" != "--locked" ]; then
    exec flock --close "$LOCK_FILE" "$0" --locked "$@"
fi
shift

if [ "$#" -ne 3 ]; then
    echo "usage: $0 COMPOSE_CMD PODMAN_PATH COMPOSE_FILE" >&2
    exit 2
fi

COMPOSE_CMD="$1"
PODMAN_PATH="$2"
COMPOSE_FILE="$3"
PROJECT_ROOT="$(cd "$(dirname "$COMPOSE_FILE")/../.." && pwd)"

# podman-compose does not reliably discover a project .env when the compose
# file lives below the repository root. Load it here for interpolation (the
# compose file still controls which variables enter each container).
if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    if ! source "$PROJECT_ROOT/.env"; then
        echo "failed to load project environment: $PROJECT_ROOT/.env" >&2
        exit 1
    fi
    set +a
fi
compose() {
    "$COMPOSE_CMD" --podman-path "$PODMAN_PATH" -f "$COMPOSE_FILE" "$@"
}

# Start ClickHouse without writers and require readiness before ingestion.
compose up -d clickhouse
clickhouse_ping=""
for _ in $(seq 1 60); do
    if clickhouse_ping="$(curl -fsS --max-time 2 http://127.0.0.1:8123/ping 2>&1)"; then
        clickhouse_ready=1
        break
    fi
    sleep 2
done
if [ "${clickhouse_ready:-0}" -ne 1 ]; then
    echo "ClickHouse did not become ready within 120 seconds: $clickhouse_ping" >&2
    exit 1
fi

# Keep this list explicit and ordered. Do not collapse it into one `up` call.
for service in vector openbao prometheus grafana etcd; do
    compose up -d "$service"
done

exec "$COMPOSE_CMD" --podman-path "$PODMAN_PATH" -f "$COMPOSE_FILE" up apisix
