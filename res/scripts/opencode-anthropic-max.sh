#!/bin/bash
set -euo pipefail

# opencode-anthropic-max.sh
# Wire the client-side Claude Pro/Max path into an OpenCode config.
#
# The gateway never handles Anthropic auth. This script only:
#   1. adds the maintained community auth plugin
#      (@ex-machina/opencode-anthropic-auth, pinned) to the OpenCode plugin
#      array, and
#   2. prints the environment the plugin needs to route model traffic through
#      the gateway (ANTHROPIC_BASE_URL).
#
# It does NOT define, override, or reference the built-in `anthropic`
# provider's baseURL: the plugin rewrites the request origin from
# ANTHROPIC_BASE_URL itself, and OAuth runs client-side directly against
# Anthropic.
#
# Usage:
#   bash res/scripts/opencode-anthropic-max.sh
#   make setup-anthropic-max
#
# Options:
#   --gateway URL       Gateway base URL (default: http://localhost:9080).
#   --plugin-version V   Pin the community plugin version (default: 1.8.5).
#   --config-file PATH   OpenCode config path (default: $OPENCODE_CONFIG_DIR/opencode.jsonc).
#   --help               Show this help.

_SELF="${BASH_SOURCE[0]}"
case "$_SELF" in
  /proc/*) _SELF="${SHG_SCRIPT_PATH:-$_SELF}" ;;
esac
REPO_ROOT="$(cd "$(dirname "$_SELF")/../.." && pwd)"
if [ ! -f "$REPO_ROOT/res/scripts/opencode-anthropic-max.sh" ]; then
  REPO_ROOT="$(pwd)"
fi
if [ ! -f "$REPO_ROOT/res/scripts/opencode-anthropic-max.sh" ]; then
  echo "ERROR: cannot locate repo root (invoked as $_SELF, cwd $(pwd))" >&2
  exit 1
fi

GATEWAY="http://localhost:9080"
PLUGIN_PACKAGE="@ex-machina/opencode-anthropic-auth"
PLUGIN_VERSION="1.8.5"
CONFIG_FILE="${OPENCODE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}/opencode.jsonc"

usage() {
  sed -n '2,25p' "$0"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --gateway)        GATEWAY="$2"; shift 2 ;;
    --plugin-version) PLUGIN_VERSION="$2"; shift 2 ;;
    --config-file)    CONFIG_FILE="$2"; shift 2 ;;
    --help)           usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

GATEWAY="${GATEWAY%/}"
if ! [[ "$GATEWAY" =~ ^https?:// ]]; then
  echo "ERROR: --gateway must be an http(s) URL (got: $GATEWAY)" >&2
  exit 1
fi
if ! [[ "$PLUGIN_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: --plugin-version must be major.minor.patch (got: $PLUGIN_VERSION)" >&2
  exit 1
fi

for dep in jq; do
  if ! command -v "$dep" 1>&2; then
    echo "ERROR: required tool not found: $dep" >&2
    exit 1
  fi
done

# Single-file guard: OpenCode deep-merges every config in the directory.
for _sibling in config.json opencode.json; do
  _sibling_path="$(dirname "$CONFIG_FILE")/$_sibling"
  if [ -s "$_sibling_path" ]; then
    echo "ERROR: conflicting OpenCode config exists: $_sibling_path" >&2
    echo "OpenCode merges it with $CONFIG_FILE. Remove the stale file, then re-run:" >&2
    echo "  rm -f \"$_sibling_path\"" >&2
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

source "$REPO_ROOT/res/scripts/opencode-client-lib.sh" || exit 1

read_config_json() {
  local path="$1"
  if [ ! -f "$path" ]; then
    echo '{}'
    return 0
  fi
  local raw
  raw=$(cat "$path")
  if _valid_json=$(jq -e . <<< "$raw"); then
    echo "$raw"
  else
    strip_jsonc_comments "$raw"
  fi
}

ENTRY="${PLUGIN_PACKAGE}@${PLUGIN_VERSION}"
CONFIG_JSON=$(read_config_json "$CONFIG_FILE")
if ! _valid_config=$(echo "$CONFIG_JSON" | jq -e .); then
  echo "ERROR: config file is not valid JSON/JSONC: $CONFIG_FILE" >&2
  exit 1
fi

# Idempotent: drop any prior spec for this package (any version), then append
# the pinned spec once. Unrelated plugin entries are preserved.
MERGED=$(echo "$CONFIG_JSON" | jq --arg pkg "$PLUGIN_PACKAGE" --arg entry "$ENTRY" '
  .plugin = (((.plugin // []) | map(select((type != "string") or (startswith($pkg) | not)))) + [$entry])')
if [ -z "$MERGED" ]; then
  echo "ERROR: failed to merge plugin entry" >&2
  exit 1
fi

mkdir -p "$(dirname "$CONFIG_FILE")"
echo "$MERGED" | jq . > "$TMPDIR/config.json"
mv "$TMPDIR/config.json" "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

echo "Anthropic (Claude Pro/Max) installed."
echo "  Config file: $CONFIG_FILE"
echo "  Plugin:      $ENTRY"
echo ""
echo "Export these before starting OpenCode so model traffic flows through the gateway:"
echo "  export ANTHROPIC_BASE_URL=${GATEWAY}/anthropic"
echo "  export ANTHROPIC_INSECURE=1   # only if the gateway uses a self-signed cert"
echo ""
echo "Then run 'opencode' and use /connect -> Anthropic -> Claude Pro/Max."
echo "OAuth runs client-side against Anthropic; the gateway only proxies model requests."
