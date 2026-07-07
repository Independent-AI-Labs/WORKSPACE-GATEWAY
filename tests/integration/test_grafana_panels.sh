#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

GRAFANA_URL="${GRAFANA_URL:-http://localhost:3030}"

WORKSPACE_ROOT="${AMI_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
NODE_BIN="${NODE_BIN:-$WORKSPACE_ROOT/.boot-linux/bin/node}"
NODE_PATH="${NODE_PATH:-$WORKSPACE_ROOT/node_modules}"
export NODE_PATH

if [ ! -f .env ]; then
    echo "[INFO] No .env file found, using defaults"
else
    set -a; source .env; set +a
fi

if ! command -v podman >/dev/null 2>&1; then
    echo "[FAIL] podman not found on PATH"
    exit 1
fi

if ! podman ps --format '{{.Names}}' | grep -q gw-grafana; then
    echo "[FAIL] gw-grafana container is not running"
    echo "       Run 'make dev-start' first"
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
    rc=$?
    echo "[FAIL] grafana_panel_check (rc=$rc)"
    exit "$rc"
fi
