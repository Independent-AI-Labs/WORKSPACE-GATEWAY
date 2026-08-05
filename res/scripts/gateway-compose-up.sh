#!/bin/bash
set -euo pipefail

# podman-compose starts independent services concurrently. That is unsafe in
# this rootless setup: APISIX can ask Podman to attach to a dependency before
# Podman has finished creating that dependency. Bootstrap each service under a
# process lock, then keep APISIX in the foreground for systemd.

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
LOCK_DIR="${XDG_RUNTIME_DIR:-/tmp}"
LOCK_FILE="$LOCK_DIR/workspace-gateway-compose.lock"

exec 9>"$LOCK_FILE"
flock -x 9

compose() {
    "$COMPOSE_CMD" --podman-path "$PODMAN_PATH" -f "$COMPOSE_FILE" "$@"
}

# Keep this list explicit and ordered. Do not collapse it into one `up` call.
for service in clickhouse vector openbao prometheus grafana etcd; do
    compose up -d "$service"
done

exec "$COMPOSE_CMD" --podman-path "$PODMAN_PATH" -f "$COMPOSE_FILE" up apisix
