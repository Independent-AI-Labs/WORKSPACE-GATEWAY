#!/usr/bin/env bash
set -euo pipefail

container_name="${APISIX_CONTAINER:-docker_apisix_1}"
drain_timeout="${DRAIN_TIMEOUT:-300}"
# Canonical runtime lives in the deployed /opt trust boundary; bare `podman`
# resolves to the root-only wrapper under systemd's minimal PATH.
PODMAN="${PODMAN_PATH:?PODMAN_PATH must be set to the absolute podman binary path (gateway-compose.sh exports it)}"

echo "=== Draining apisix (SIGQUIT; in-flight streams finish, ${drain_timeout}s max) ==="
if "$PODMAN" stop -t "$drain_timeout" "$container_name"; then
    exit 0
fi

  echo "=== WARN: drain failed; forcing stop ===" >&2
"$PODMAN" stop -t 5 "$container_name"
