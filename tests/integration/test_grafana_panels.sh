#!/bin/bash
set -euo pipefail

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
    _SELF="$SHG_SCRIPT_PATH"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

GRAFANA_URL="${GRAFANA_URL:-http://localhost:3030}"

if [ -z "${AMI_ROOT+x}" ]; then
    WORKSPACE_ROOT="$(cd "$REPO_ROOT/../.." && pwd)"
else
    WORKSPACE_ROOT="$AMI_ROOT"
fi
if [ -z "${NODE_BIN+x}" ]; then
    NODE_BIN="$WORKSPACE_ROOT/.boot-linux/bin/node"
fi
NODE_PATH="${NODE_PATH:-$WORKSPACE_ROOT/node_modules}"
export NODE_PATH
if [ -z "${PLAYWRIGHT_BROWSERS_PATH+x}" ]; then
    PLAYWRIGHT_BROWSERS_PATH="$WORKSPACE_ROOT/.boot-linux/playwright-browsers"
fi
export PLAYWRIGHT_BROWSERS_PATH

if [ ! -f .env ]; then
    echo "[INFO] No .env file found, using defaults"
else
    set -a; source .env; set +a
fi

if ! command -v podman 1>&2; then
    echo "[FAIL] podman not found on PATH"
    exit 1
fi

if ! podman ps --format '{{.Names}}' | grep -q -E '(gw-grafana|gw-test.*grafana)'; then
    echo "[FAIL] Grafana container is not running"
    echo "       Run 'make gw-start' first"
    exit 1
fi

if [ ! -x "$NODE_BIN" ]; then
    echo "[FAIL] Node.js binary not found or not executable: $NODE_BIN"
    echo "       Install Node.js or set NODE_BIN env var"
    exit 1
fi

echo "=== Grafana Panel Rendering Tests (Playwright) ==="
echo "  Grafana URL: $GRAFANA_URL"
echo "  Node:        $NODE_BIN ($($NODE_BIN --version))"
echo ""

if "$NODE_BIN" "$SCRIPT_DIR/grafana_panel_check.js" --url "$GRAFANA_URL"; then
    echo "[PASS] grafana_panel_check"
    exit 0
else
    status=$?
    echo "[FAIL] grafana_panel_check (status=$status)"
    exit "$status"
fi
