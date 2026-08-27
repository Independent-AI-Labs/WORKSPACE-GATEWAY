#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(pwd -P)"
CLIENT="$REPO_ROOT/res/scripts/gateway-compose.sh"
export SHG_SCRIPT_PATH="$CLIENT"
DRY_RUN=$(make -n gw-restart-service SVC=apisix)
if grep -qF 'podman-compose' <<< "$DRY_RUN"; then
    echo "make recipe still embeds podman-compose" >&2
    exit 1
fi

RESTART_PLAN=$(make -n gw-restart)
if grep -qF 'gw-build' <<< "$RESTART_PLAN"; then
    echo "gw-restart unexpectedly builds images" >&2
    exit 1
fi

UPDATE_PLAN=$(make -n gw-update)
if ! grep -qF 'gw-build' <<< "$UPDATE_PLAN"; then
    echo "gw-update does not build images" >&2
    exit 1
fi

if ! grep -qF 'admin-key-file' "$REPO_ROOT/res/scripts/seed-routes.sh"; then
    echo "route seeding lacks file-based credential input" >&2
    exit 1
fi

if grep -qF 'Restart=always' "$REPO_ROOT/res/ansible/templates/gateway-compose.service.j2"; then
    echo "systemd unit still has duplicate restart ownership" >&2
    exit 1
fi

if ! grep -qF 'gateway-compose-up.sh' "$REPO_ROOT/res/ansible/templates/gateway-compose.service.j2"; then
    echo "systemd unit does not use the serialized compose bootstrap" >&2
    exit 1
fi

if ! grep -qF 'flock --close' "$REPO_ROOT/res/scripts/gateway-compose-up.sh"; then
    echo "serialized compose bootstrap leaks its exclusive lock" >&2
    exit 1
fi

if ! grep -qF 'PROJECT_ROOT/.env' "$REPO_ROOT/res/scripts/gateway-compose-up.sh"; then
    echo "serialized compose bootstrap does not load project interpolation env" >&2
    exit 1
fi

if ! grep -qF 'compose up -d clickhouse' "$REPO_ROOT/res/scripts/gateway-compose-up.sh"; then
    echo "serialized compose bootstrap does not isolate ClickHouse startup" >&2
    exit 1
fi

if ! grep -qF 'for service in vector openbao prometheus grafana etcd' \
    "$REPO_ROOT/res/scripts/gateway-compose-up.sh"; then
    echo "serialized compose bootstrap does not start dependencies in order" >&2
    exit 1
fi

if ! grep -qF 'kill -TERM "$BAO_PID"' "$REPO_ROOT/res/docker/openbao-entrypoint.sh"; then
    echo "OpenBao entrypoint lacks signal forwarding" >&2
    exit 1
fi

if ! grep -qF 'Verified exact managed route set' "$REPO_ROOT/res/scripts/seed-routes.sh"; then
    echo "route reconciliation lacks exact-set verification" >&2
    exit 1
fi

echo "gateway compose wrapper tests: passed"
