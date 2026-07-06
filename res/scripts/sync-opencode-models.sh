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
# Requires: curl, jq, python3
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
GW_MODELS_FILE="$TMPDIR_SYNC/gateway_models.json"
MD_RESPONSE_FILE="$TMPDIR_SYNC/models_dev.json"

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

echo "=== Updating opencode config ==="
echo "  Config: $OPENCODE_CONFIG"
echo "  Providers: workspace-gw-private (virtual key), workspace-gw-own (own key)"
echo "  Context limit: ${CONTEXT_LIMIT_PCT}% (ceiling: ${CONTEXT_LIMIT_CEILING})"

python3 - "$OPENCODE_CONFIG" "$GATEWAY_URL" "$GATEWAY_API_KEY" "$GW_MODELS_FILE" "$MD_RESPONSE_FILE" "$CONTEXT_LIMIT_PCT" "$CONTEXT_LIMIT_CEILING" <<'PYEOF'
import json
import os
import re
import sys

config_path = sys.argv[1]
gateway_url = sys.argv[2]
gateway_api_key = sys.argv[3]
gateway_models_file = sys.argv[4]
models_dev_file = sys.argv[5]
context_limit_pct = int(sys.argv[6])
context_limit_ceiling = int(sys.argv[7])

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

with open(gateway_models_file, 'r') as f:
    gateway_model_ids = json.load(f)
with open(models_dev_file, 'r') as f:
    models_dev_raw = json.load(f)

opencode_provider = models_dev_raw.get("opencode", {})
md_models = opencode_provider.get("models", {})

def scale_limit(val):
    if val is None:
        return None
    scaled = int(val * context_limit_pct / 100)
    if context_limit_ceiling > 0 and scaled > context_limit_ceiling:
        scaled = context_limit_ceiling
    return scaled

def build_model_entry(model_id, md):
    entry = {}
    if md:
        if "name" in md:
            entry["name"] = md["name"]
        if "family" in md:
            entry["family"] = md["family"]
        if "release_date" in md:
            entry["release_date"] = md["release_date"]
        if "attachment" in md:
            entry["attachment"] = md["attachment"]
        if "reasoning" in md:
            entry["reasoning"] = md["reasoning"]
        if "temperature" in md:
            entry["temperature"] = md["temperature"]
        if "tool_call" in md:
            entry["tool_call"] = md["tool_call"]
        if "interleaved" in md:
            entry["interleaved"] = md["interleaved"]
        if "status" in md:
            entry["status"] = md["status"]

        cost = md.get("cost")
        if cost:
            cost_entry = {
                "input": cost.get("input", 0),
                "output": cost.get("output", 0),
            }
            if "cache_read" in cost:
                cost_entry["cache_read"] = cost["cache_read"]
            if "cache_write" in cost:
                cost_entry["cache_write"] = cost["cache_write"]
            entry["cost"] = cost_entry

        limit = md.get("limit")
        if limit:
            limit_entry = {}
            if "context" in limit:
                limit_entry["context"] = scale_limit(limit["context"])
            if "input" in limit:
                limit_entry["input"] = scale_limit(limit["input"])
            if "output" in limit:
                limit_entry["output"] = limit["output"]
            entry["limit"] = limit_entry

        modalities = md.get("modalities")
        if modalities:
            mod_entry = {}
            if "input" in modalities:
                mod_entry["input"] = modalities["input"]
            if "output" in modalities:
                mod_entry["output"] = modalities["output"]
            entry["modalities"] = mod_entry
    else:
        entry["name"] = model_id
        entry["limit"] = {"context": 0, "output": 0}
    return entry

enriched_count = 0
bare_count = 0
models_dict = {}
for mid in sorted(gateway_model_ids):
    md = md_models.get(mid)
    if md:
        enriched_count += 1
    else:
        bare_count += 1
    models_dict[mid] = build_model_entry(mid, md)

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

for stale in ('zen_federated', 'zen', 'workspace-gateway', 'opencode_federated', 'opencode'):
    config['provider'].pop(stale, None)

config['provider']['workspace-gw-private'] = {
    'name': 'Workspace GW (Virtual Key)',
    'api': gateway_url + '/opencode_federated/v1',
    'npm': '@ai-sdk/openai-compatible',
    'options': {
        'baseURL': gateway_url + '/opencode_federated/v1',
        'apiKey': gateway_api_key,
        'headers': {
            'X-Tenant-ID': 'default',
            'X-User-ID': 'agent',
        },
    },
    'models': models_dict,
}

config['provider']['workspace-gw-own'] = {
    'name': 'Workspace GW (Own Key)',
    'api': gateway_url + '/opencode/v1',
    'npm': '@ai-sdk/openai-compatible',
    'options': {
        'baseURL': gateway_url + '/opencode/v1',
        'headers': {
            'X-Tenant-ID': 'default',
            'X-User-ID': 'agent',
        },
    },
    'models': {k: dict(v) for k, v in models_dict.items()},
}

os.makedirs(os.path.dirname(config_path), exist_ok=True)
with open(config_path, 'w') as f:
    json.dump(config, f, indent=2)
    f.write('\n')

print('  Wrote ' + str(len(models_dict)) + ' models to ' + config_path)
print('    Enriched from models.dev: ' + str(enriched_count))
print('    Bare (no models.dev match): ' + str(bare_count))
print('    Context limit: ' + str(context_limit_pct) + '% (ceiling: ' + str(context_limit_ceiling) + ')')
print('    workspace-gw-private: ' + str(len(models_dict)) + ' models (virtual key)')
print('    workspace-gw-own:     ' + str(len(models_dict)) + ' models (own key)')
PYEOF

echo "=== Done ==="
