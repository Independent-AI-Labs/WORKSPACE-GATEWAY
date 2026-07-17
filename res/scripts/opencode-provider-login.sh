#!/bin/bash
set -euo pipefail

# opencode-provider-login.sh
# Generic thin client for setting up an OpenCode provider from WORKSPACE-GATEWAY.
#
# Fetches the provider block from the gateway's provider-sync service, performs
# provider-specific authentication, and writes the provider into the user's
# OpenCode config and auth files.
#
# Usage:
#   bash res/scripts/opencode-provider-login.sh --provider-id workspace-gw-kimi-oauth
#
# Options:
#   --provider-id ID       Provider ID (required).
#   --gateway URL        Gateway base URL (default: http://localhost:9080).
#   --session ID          OAuth session label (default: opencode-<timestamp>).
#   --config-file PATH    OpenCode config path (default: ~/.config/opencode/opencode.jsonc or .json).
#   --auth-file PATH      OpenCode auth path (default: ~/.local/share/opencode/auth.json).
#   --user-agent UA       User-Agent sent on all requests (default: Kimi CLI string).
#   --no-browser          Do not open the browser for OAuth.
#   --no-prompt           Do not prompt for API keys (fail if needed).
#   --device-timeout SEC  OAuth polling timeout in seconds (default: 900).
#   --help                Show this help.

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

GATEWAY="http://localhost:9080"
PROVIDER_ID=""
SESSION="opencode-$(date +%s)"
if [ -f "${HOME}/.config/opencode/opencode.jsonc" ]; then
  CONFIG_FILE="${HOME}/.config/opencode/opencode.jsonc"
else
  CONFIG_FILE="${HOME}/.config/opencode/opencode.json"
fi
AUTH_FILE="${HOME}/.local/share/opencode/auth.json"
USER_AGENT="Kimi CLI (Linux 6.17.0-35-generic x64)"
NO_BROWSER=0
NO_PROMPT=0
DEVICE_TIMEOUT=900

usage() {
  sed -n '2,25p' "$0"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --provider-id)    PROVIDER_ID="$2"; shift 2 ;;
    --gateway)        GATEWAY="$2"; shift 2 ;;
    --session)        SESSION="$2"; shift 2 ;;
    --config-file)    CONFIG_FILE="$2"; shift 2 ;;
    --auth-file)      AUTH_FILE="$2"; shift 2 ;;
    --user-agent)     USER_AGENT="$2"; shift 2 ;;
    --no-browser)     NO_BROWSER=1; shift ;;
    --no-prompt)      NO_PROMPT=1; shift ;;
    --device-timeout) DEVICE_TIMEOUT="$2"; shift 2 ;;
    --help)           usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [ -z "$PROVIDER_ID" ]; then
  echo "ERROR: --provider-id is required" >&2
  usage >&2
  exit 1
fi

GATEWAY="${GATEWAY%/}"

if ! [[ "$GATEWAY" =~ ^https?:// ]]; then
  echo "ERROR: --gateway must be an http(s) URL (got: $GATEWAY)" >&2
  exit 1
fi

if ! [[ "$DEVICE_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$DEVICE_TIMEOUT" -le 0 ]; then
  echo "ERROR: --device-timeout must be a positive integer (got: $DEVICE_TIMEOUT)" >&2
  exit 1
fi

for dep in curl jq; do
  if ! command -v "$dep" 1>&2; then
    echo "ERROR: required tool not found: $dep" >&2
    exit 1
  fi
done

TMPDIR=""
cleanup() {
  if [ -n "$TMPDIR" ] && [ -d "$TMPDIR" ]; then
    rm -rf "$TMPDIR"
  fi
}
trap cleanup EXIT
TMPDIR="$(mktemp -d)"
chmod 755 "$TMPDIR"

curl_json() {
  local url="$1"
  shift
  curl -sS -A "$USER_AGENT" --max-time 15 "$url" "$@"
}

# Strip // and /* */ comments from JSONC while respecting string literals.
# Slow but dependency-free; works for the small OpenCode config files.
strip_jsonc_comments() {
  local input="$1"
  local output=""
  local in_string=0
  local in_line_comment=0
  local in_block_comment=0
  local escaped=0
  local len=${#input}

  for (( i=0; i<len; i++ )); do
    local ch="${input:$i:1}"
    if [ $in_string -eq 1 ]; then
      if [ $escaped -eq 1 ]; then
        escaped=0
      elif [ "$ch" = "\\" ]; then
        escaped=1
      elif [ "$ch" = '"' ]; then
        in_string=0
      fi
      output="${output}${ch}"
    elif [ $in_line_comment -eq 1 ]; then
      if [ "$ch" = $'\n' ]; then
        in_line_comment=0
        output="${output}${ch}"
      fi
    elif [ $in_block_comment -eq 1 ]; then
      if [ "$ch" = "*" ]; then
        local next="${input:$((i+1)):1}"
        if [ "$next" = "/" ]; then
          in_block_comment=0
          i=$((i+1))
        fi
      fi
    else
      if [ "$ch" = '"' ]; then
        in_string=1
        output="${output}${ch}"
      elif [ "$ch" = "/" ]; then
        local next="${input:$((i+1)):1}"
        if [ "$next" = "/" ]; then
          in_line_comment=1
          i=$((i+1))
        elif [ "$next" = "*" ]; then
          in_block_comment=1
          i=$((i+1))
        else
          output="${output}${ch}"
        fi
      else
        output="${output}${ch}"
      fi
    fi
  done
  echo "$output"
}

read_config_json() {
  local path="$1"
  if [ ! -f "$path" ]; then
    echo '{"provider":{}}'
    return 0
  fi
  local raw
  raw=$(cat "$path")
  # If plain JSON, jq will parse it; if JSONC, strip comments first.
  if _valid_json=$(jq -e . <<< "$raw"); then
    echo "$raw"
  else
    strip_jsonc_comments "$raw"
  fi
}

prompt_for_key() {
  local prompt="$1"
  local key
  read -rsp "$prompt" key >&2
  echo "" >&2
  echo "$key"
}

# --- Fetch provider config from gateway ---
echo "=== OpenCode Provider Login ==="
echo "  Provider:       $PROVIDER_ID"
echo "  Gateway:        $GATEWAY"
echo "  Session:        $SESSION"
echo "  Config:         $CONFIG_FILE"
echo "  Auth file:      $AUTH_FILE"
echo ""

OPENCODE_RESP=$(curl_json "${GATEWAY}/gateway/providers/${PROVIDER_ID}/opencode" -H "Accept: application/json")
if ! _provider=$(echo "$OPENCODE_RESP" | jq -e '.provider'); then
  echo "ERROR: gateway returned an invalid provider response:" >&2
  echo "$OPENCODE_RESP" | jq . >&2
  exit 1
fi

AUTH_TYPE=$(echo "$OPENCODE_RESP" | jq -r '.auth_type // "none"')
AUTH_ROUTE=$(echo "$OPENCODE_RESP" | jq -r '.auth_route // empty')
PROVIDER_NAME=$(echo "$OPENCODE_RESP" | jq -r '.provider.name // empty')

echo "Provider: $PROVIDER_NAME"
echo "Auth type: $AUTH_TYPE"
echo ""

ACCESS_TOKEN=""
USER_KEY=""

# --- Provider-specific authentication ---
if [ "$AUTH_TYPE" = "oauth" ]; then
  if [ -z "$AUTH_ROUTE" ]; then
    echo "ERROR: provider response missing auth_route for OAuth provider" >&2
    exit 1
  fi

  echo "Starting OAuth device flow..."
  DEVICE_RESP=$(curl_json -X POST "${GATEWAY}${AUTH_ROUTE}/device?session=${SESSION}" -H "Accept: application/json") || {
    echo "ERROR: device flow request failed" >&2
    exit 1
  }

  USER_CODE=$(echo "$DEVICE_RESP" | jq -r '.user_code // empty')
  DEVICE_CODE=$(echo "$DEVICE_RESP" | jq -r '.device_code // empty')
  VERIFICATION_URI_COMPLETE=$(echo "$DEVICE_RESP" | jq -r '.verification_uri_complete // empty')
  INTERVAL=$(echo "$DEVICE_RESP" | jq -r '.interval // 5')
  EXPIRES_IN=$(echo "$DEVICE_RESP" | jq -r '.expires_in // 900')

  if [ -z "$USER_CODE" ] || [ -z "$DEVICE_CODE" ]; then
    echo "ERROR: gateway returned an invalid device response:" >&2
    echo "$DEVICE_RESP" | jq . >&2
    exit 1
  fi

  echo "User code: $USER_CODE"
  echo "Verification URL: $VERIFICATION_URI_COMPLETE"
  echo ""

  if [ "$NO_BROWSER" -eq 0 ]; then
    if command -v xdg-open 1>&2; then
      if ! xdg-open "$VERIFICATION_URI_COMPLETE" 1>&2; then
        echo "WARN: xdg-open failed, continuing" >&2
      fi
    elif command -v gnome-open 1>&2; then
      if ! gnome-open "$VERIFICATION_URI_COMPLETE" 1>&2; then
        echo "WARN: gnome-open failed, continuing" >&2
      fi
    elif command -v kde-open 1>&2; then
      if ! kde-open "$VERIFICATION_URI_COMPLETE" 1>&2; then
        echo "WARN: kde-open failed, continuing" >&2
      fi
    elif command -v open 1>&2; then
      if ! open "$VERIFICATION_URI_COMPLETE" 1>&2; then
        echo "WARN: open failed, continuing" >&2
      fi
    fi
  fi

  echo "Polling for authorization..."
  POLL_INTERVAL=$INTERVAL
  START_TIME=$(date +%s)
  DEADLINE=$((START_TIME + DEVICE_TIMEOUT))

  while true; do
    NOW=$(date +%s)
    if [ "$NOW" -ge "$DEADLINE" ]; then
      echo "ERROR: device code expired locally after ${DEVICE_TIMEOUT}s" >&2
      exit 1
    fi

    POLL_RESP=$(curl_json -X POST "${GATEWAY}${AUTH_ROUTE}/device/poll" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      -d "{\"device_code\":\"${DEVICE_CODE}\"}") || {
      echo "ERROR: poll request failed" >&2
      exit 1
    }

    ACCESS_TOKEN=$(echo "$POLL_RESP" | jq -r '.access_token // empty')
    if [ -n "$ACCESS_TOKEN" ]; then
      break
    fi

    ERROR_CODE=$(echo "$POLL_RESP" | jq -r '.error_code // .error // empty')
    case "$ERROR_CODE" in
      authorization_pending)
        echo "  waiting for authorization..."
        ;;
      slow_down)
        echo "  gateway asked to slow down; adding 5s..."
        POLL_INTERVAL=$((POLL_INTERVAL + 5))
        ;;
      expired_token)
        echo "ERROR: device code expired" >&2
        exit 1
        ;;
      access_denied)
        echo "ERROR: authorization denied" >&2
        exit 1
        ;;
      "")
        echo "ERROR: unexpected poll response:" >&2
        echo "$POLL_RESP" | jq . >&2
        exit 1
        ;;
      *)
        echo "ERROR: poll failed: $ERROR_CODE" >&2
        echo "$POLL_RESP" | jq . >&2
        exit 1
        ;;
    esac

    sleep "$POLL_INTERVAL"
  done

  echo ""
  echo "OAuth authorization complete."
  echo ""

elif [ "$AUTH_TYPE" = "api_key" ] || [ "$AUTH_TYPE" = "virtual_key" ]; then
  if [ "$NO_PROMPT" -eq 1 ]; then
    echo "ERROR: provider requires an API key but --no-prompt is set" >&2
    exit 1
  fi
  USER_KEY=$(prompt_for_key "Enter API key for ${PROVIDER_NAME}: ")
  if [ -z "$USER_KEY" ]; then
    echo "ERROR: API key is required" >&2
    exit 1
  fi

elif [ "$AUTH_TYPE" = "none" ] || [ "$AUTH_TYPE" = "passthrough" ]; then
  echo "No authentication required for this provider."
  echo ""
else
  echo "ERROR: unsupported auth_type: $AUTH_TYPE" >&2
  exit 1
fi

# --- Merge provider block into OpenCode config ---
mkdir -p "$(dirname "$CONFIG_FILE")"
mkdir -p "$(dirname "$AUTH_FILE")"

CONFIG_JSON=$(read_config_json "$CONFIG_FILE")
PROVIDER_BLOCK=$(echo "$OPENCODE_RESP" | jq '.provider')

if ! _valid_config=$(echo "$CONFIG_JSON" | jq -e .); then
  echo "ERROR: config file is not valid JSON/JSONC: $CONFIG_FILE" >&2
  exit 1
fi

# Ensure top-level provider key exists.
CONFIG_JSON=$(echo "$CONFIG_JSON" | jq '.provider = (.provider // {})')

# Replace/insert the provider entry.
MERGED_CONFIG=$(echo "$CONFIG_JSON" | jq --arg id "$PROVIDER_ID" --argjson block "$PROVIDER_BLOCK" \
  '.provider[$id] = $block')

if [ -z "$MERGED_CONFIG" ]; then
  echo "ERROR: failed to merge provider into config" >&2
  exit 1
fi

# Pretty-print and write back.
echo "$MERGED_CONFIG" | jq . > "$TMPDIR/config.json"
if [ ! -s "$TMPDIR/config.json" ]; then
  echo "ERROR: failed to write merged config" >&2
  exit 1
fi
mv "$TMPDIR/config.json" "$CONFIG_FILE"

# --- Write auth.json ---
AUTH_JSON='{}'
if [ -f "$AUTH_FILE" ]; then
  AUTH_JSON=$(cat "$AUTH_FILE")
  if ! _valid_auth=$(echo "$AUTH_JSON" | jq -e .); then
    echo "ERROR: auth file is not valid JSON: $AUTH_FILE" >&2
    exit 1
  fi
fi

if [ "$AUTH_TYPE" = "oauth" ] && [ -n "$ACCESS_TOKEN" ]; then
  AUTH_JSON=$(echo "$AUTH_JSON" | jq --arg id "$PROVIDER_ID" --arg key "$ACCESS_TOKEN" \
    '.[$id] = {type: "api", key: $key}')
elif [ "$AUTH_TYPE" = "api_key" ] || [ "$AUTH_TYPE" = "virtual_key" ]; then
  AUTH_JSON=$(echo "$AUTH_JSON" | jq --arg id "$PROVIDER_ID" --arg key "$USER_KEY" \
    '.[$id] = {type: "api", key: $key}')
fi

echo "$AUTH_JSON" | jq . > "$TMPDIR/auth.json"
if [ ! -s "$TMPDIR/auth.json" ]; then
  echo "ERROR: failed to write auth file" >&2
  exit 1
fi
mv "$TMPDIR/auth.json" "$AUTH_FILE"
chmod 600 "$AUTH_FILE"

# --- Summary ---
echo ""
echo "=== Login complete ==="
echo "  Provider id: $PROVIDER_ID"
echo "  Config file: $CONFIG_FILE"
echo "  Auth file:   $AUTH_FILE"
echo ""
echo "Run a quick chat with:"
echo "  opencode -m ${PROVIDER_ID}/<model-id>"
echo ""
echo "Or start the TUI and select the '${PROVIDER_NAME}' provider."
