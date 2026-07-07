#!/bin/bash
set -euo pipefail

# sync-opencode-models.sh
# Fetches the model list from the WORKSPACE-GATEWAY federated route
# (/opencode_federated/v1/models) using the virtual gateway key, then enriches
# each model with canonical metadata (name, context limit, capabilities,
# cost, modalities) from models.dev, and writes TWO provider entries
# into the opencode user config:
#
#   workspace-gw-private - virtual-key mode (apiKey = vgw-gateway-key)
#     display name: "Workspace GW (Virtual Key)"
#   workspace-gw-own     - own-key passthrough (no apiKey, client provides key)
#     display name: "Workspace GW (Own Key)"
#
# Both providers receive the full enriched model catalog so opencode does
# not drop them (opencode deletes providers with zero models).
#
# Context limits are scaled by CONTEXT_LIMIT_PCT (default 100) from .env,
# so e.g. CONTEXT_LIMIT_PCT=80 reduces a 200000-token context to 160000.
# An absolute ceiling CONTEXT_LIMIT_CEILING (default 128000) is then applied:
# any scaled value exceeding the ceiling is clamped to it. Set to 0 to disable.
#
# Usage:
#   make sync-models
#   bash res/scripts/sync-opencode-models.sh
#
# Requires: curl, jq, podman (for Lua execution via APISIX container)
# Requires: gateway stack running (make dev-start)

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"
GATEWAY_URL="${GATEWAY_URL:-http://localhost:9080}"
GATEWAY_API_KEY="${GATEWAY_API_KEY:-vgw-gateway-key}"
OPENCODE_CONFIG="${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.jsonc}"
MODELS_DEV_URL="${MODELS_DEV_URL:-https://models.dev/api.json}"

TMPDIR_SYNC=""
cleanup() {
  if [ -n "$TMPDIR_SYNC" ] && [ -d "$TMPDIR_SYNC" ]; then
    rm -rf "$TMPDIR_SYNC"
  fi
}
trap cleanup EXIT

if [ -f "$ENV_FILE" ]; then
  set -a
  source "$ENV_FILE" || exit 1
  set +a
fi

GATEWAY_API_KEY="${GATEWAY_API_KEY:-vgw-gateway-key}"
GATEWAY_URL="${GATEWAY_URL:-http://localhost:9080}"
CONTEXT_LIMIT_PCT="${CONTEXT_LIMIT_PCT:-100}"
CONTEXT_LIMIT_CEILING="${CONTEXT_LIMIT_CEILING:-128000}"

FEDERATED_MODELS_URL="$GATEWAY_URL/opencode_federated/v1/models"
TMPDIR_SYNC="$(mktemp -d)"
chmod 755 "$TMPDIR_SYNC"
GW_MODELS_FILE="$TMPDIR_SYNC/gateway_models.json"
MD_RESPONSE_FILE="$TMPDIR_SYNC/models_dev.json"
CONFIG_COPY="$TMPDIR_SYNC/opencode_config.jsonc"
LUA_STDERR="$TMPDIR_SYNC/lua_stderr.txt"

echo "=== Fetching models from gateway (federated route) ==="
echo "  URL: $FEDERATED_MODELS_URL"
echo "  Key: $GATEWAY_API_KEY"

GATEWAY_RESPONSE=$(curl -sSf \
  -H "Authorization: Bearer $GATEWAY_API_KEY" \
  "$FEDERATED_MODELS_URL") || {
  echo "ERROR: failed to fetch models from gateway at $GATEWAY_URL" >&2
  echo "  Is the gateway running? Try: make dev-start" >&2
  echo "  Is the virtual key provisioned? Check OpenBao." >&2
  exit 1
}

echo "$GATEWAY_RESPONSE" | jq -c '[.data[].id]' > "$GW_MODELS_FILE" || {
  echo "ERROR: failed to parse model list from gateway response" >&2
  exit 1
}

GATEWAY_MODEL_COUNT=$(jq 'length' "$GW_MODELS_FILE")
echo "  Found $GATEWAY_MODEL_COUNT models"

if [ "$GATEWAY_MODEL_COUNT" -eq 0 ]; then
  echo "ERROR: gateway returned zero models" >&2
  exit 1
fi

echo "=== Fetching model metadata from models.dev ==="
echo "  URL: $MODELS_DEV_URL"

if curl -sSf --max-time 15 "$MODELS_DEV_URL" > "$MD_RESPONSE_FILE"; then
  echo "  OK"
else
  echo "WARNING: failed to fetch models.dev, proceeding with bare model IDs" >&2
  echo '{}' > "$MD_RESPONSE_FILE"
fi

# Copy existing opencode config into temp dir for container access
if [ -f "$OPENCODE_CONFIG" ]; then
  cp "$OPENCODE_CONFIG" "$CONFIG_COPY"
else
  echo "" > "$CONFIG_COPY"
fi

echo "=== Updating opencode config ==="
echo "  Config: $OPENCODE_CONFIG"
echo "  Providers: workspace-gw-private (virtual key), workspace-gw-own (own key)"
echo "  Context limit: ${CONTEXT_LIMIT_PCT}% (ceiling: ${CONTEXT_LIMIT_CEILING})"

# Run Lua enrichment script inside APISIX container (has cjson.safe).
# Lua reads temp files, outputs compact JSON to stdout, status to stderr.
# Shell captures stdout, pipes through jq for pretty-print, writes to config.
mkdir -p "$(dirname "$OPENCODE_CONFIG")"

LUA_JSON=$(podman run --rm \
  -e 'LUA_PATH=/usr/local/apisix/deps/share/lua/5.1/?.lua;/usr/local/apisix/deps/share/lua/5.1/?/init.lua;;' \
  -e 'LUA_CPATH=/usr/local/apisix/deps/lib/lua/5.1/?.so;;' \
  -v "$TMPDIR_SYNC:/sync-tmp:ro" \
  -v "$REPO_ROOT/res/scripts/sync-opencode-models.lua:/sync.lua:ro" \
  --entrypoint /usr/local/openresty/luajit/bin/luajit \
  apache/apisix:3.17.0-debian \
  /sync.lua \
  /sync-tmp/opencode_config.jsonc \
  "$GATEWAY_URL" \
  "$GATEWAY_API_KEY" \
  /sync-tmp/gateway_models.json \
  /sync-tmp/models_dev.json \
  "$CONTEXT_LIMIT_PCT" \
  "$CONTEXT_LIMIT_CEILING" \
  2>"$LUA_STDERR") || {
  echo "ERROR: Lua enrichment script failed" >&2
  cat "$LUA_STDERR" >&2
  exit 1
}

# Show Lua status messages (from stderr)
cat "$LUA_STDERR" >&2

# Pretty-print JSON and write to config
echo "$LUA_JSON" | jq . > "$OPENCODE_CONFIG"

echo "=== Done ==="
