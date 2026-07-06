#!/bin/bash
set -euo pipefail

# sync-opencode-models.sh
# Fetches the model list from the WORKSPACE-GATEWAY and writes a
# "workspace-gateway" provider entry into the opencode user config
# with every model ID listed so opencode does not drop the provider.
#
# Usage:
#   make sync-models
#   bash res/scripts/sync-opencode-models.sh
#
# Requires: curl, jq, python3
# Requires: gateway stack running (make dev-start)

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"
GATEWAY_URL="${GATEWAY_URL:-http://localhost:9080}"
GATEWAY_API_KEY="${GATEWAY_API_KEY:-vgw-gateway-key}"
OPENCODE_CONFIG="${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.jsonc}"
PROVIDER_ID="workspace-gateway"

if [ -f "$ENV_FILE" ]; then
  set -a
  source "$ENV_FILE" || exit 1
  set +a
fi

GATEWAY_API_KEY="${GATEWAY_API_KEY:-vgw-gateway-key}"
GATEWAY_URL="${GATEWAY_URL:-http://localhost:9080}"

echo "=== Fetching models from gateway ==="
echo "  URL: $GATEWAY_URL/zen/v1/models"

RESPONSE=$(curl -sSf \
  -H "Authorization: Bearer $GATEWAY_API_KEY" \
  "$GATEWAY_URL/zen/v1/models") || {
  echo "ERROR: failed to fetch models from gateway at $GATEWAY_URL" >&2
  echo "  Is the gateway running? Try: make dev-start" >&2
  exit 1
}

MODELS_JSON=$(echo "$RESPONSE" | jq -c '[.data[].id]') || {
  echo "ERROR: failed to parse model list from gateway response" >&2
  exit 1
}

MODEL_COUNT=$(echo "$MODELS_JSON" | jq 'length')
echo "  Found $MODEL_COUNT models"

if [ "$MODEL_COUNT" -eq 0 ]; then
  echo "ERROR: gateway returned zero models" >&2
  exit 1
fi

echo "=== Updating opencode config ==="
echo "  Config: $OPENCODE_CONFIG"
echo "  Provider: $PROVIDER_ID"

python3 - "$OPENCODE_CONFIG" "$PROVIDER_ID" "$GATEWAY_URL" "$GATEWAY_API_KEY" "$MODELS_JSON" <<'PYEOF'
import json
import os
import re
import sys

config_path = sys.argv[1]
provider_id = sys.argv[2]
gateway_url = sys.argv[3]
gateway_api_key = sys.argv[4]
model_ids = json.loads(sys.argv[5])

def strip_jsonc_comments(text):
    result = []
    in_string = False
    escape = False
    i = 0
    while i < len(text):
        ch = text[i]
        if escape:
            result.append(ch)
            escape = False
            i += 1
            continue
        if ch == '\\':
            result.append(ch)
            escape = True
            i += 1
            continue
        if ch == '"':
            in_string = not in_string
            result.append(ch)
            i += 1
            continue
        if not in_string and ch == '/' and i + 1 < len(text):
            if text[i + 1] == '/':
                while i < len(text) and text[i] != '\n':
                    i += 1
                continue
            if text[i + 1] == '*':
                i += 2
                while i + 1 < len(text) and not (text[i] == '*' and text[i + 1] == '/'):
                    i += 1
                i += 2
                continue
        result.append(ch)
        i += 1
    return ''.join(result)

if os.path.exists(config_path):
    with open(config_path, 'r') as f:
        raw = f.read()
    stripped = strip_jsonc_comments(raw)
    stripped = re.sub(r',\s*([}\]])', r'\1', stripped)
    config = json.loads(stripped)
else:
    config = {}

if 'provider' not in config or not isinstance(config['provider'], dict):
    config['provider'] = {}

removed = []
if 'opencode' in config['provider']:
    del config['provider']['opencode']
    removed.append('opencode')

config['provider'][provider_id] = {
    'api': gateway_url + '/zen/v1',
    'options': {
        'baseURL': gateway_url + '/zen/v1',
        'apiKey': gateway_api_key,
        'headers': {
            'X-Tenant-ID': 'default',
            'X-User-ID': 'agent',
        },
    },
    'models': {mid: {} for mid in sorted(model_ids)},
}

os.makedirs(os.path.dirname(config_path), exist_ok=True)
with open(config_path, 'w') as f:
    json.dump(config, f, indent=2)
    f.write('\n')

if removed:
    print('  Removed incorrect provider override: ' + ', '.join(removed))
print('  Wrote ' + str(len(model_ids)) + ' models to ' + config_path)
PYEOF

echo "=== Done ==="
