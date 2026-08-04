#!/usr/bin/env bash
set -euo pipefail

container_name="${APISIX_CONTAINER:-docker_apisix_1}"
drain_timeout="${DRAIN_TIMEOUT:-300}"

echo "=== Draining apisix (SIGQUIT; in-flight streams finish, ${drain_timeout}s max) ==="
if podman stop -t "$drain_timeout" "$container_name"; then
    exit 0
fi

  echo "=== WARN: drain failed; forcing stop ===" >&2
podman stop -t 5 "$container_name"
