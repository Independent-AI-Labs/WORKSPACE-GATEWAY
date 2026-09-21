#!/usr/bin/env bash
set -euo pipefail

# seed-routes.sh
# Reads conf/apisix.yaml and seeds each route into the APISIX Admin API.
# Designed for the role switch from standalone (yaml) to traditional (etcd).
#
# Admin transport: the Admin API port (9180) is NOT published to the host
# (REQ-SECURITY-HARDENING FR-6.2) and rootless podman container IPs are not
# host-routable, so by default calls run through the reviewed exec wrapper
# (res/scripts/gateway-compose.sh exec apisix -- curl). Set ADMIN_URL to hit
# a stack that does publish the Admin API (e.g. the test fixture's loopback
# forward).
#
# Usage: seed-routes.sh [--admin-key <key>] [--admin-key-file <path>] [--admin-url <url>] [--apisix-yaml <path>]
# Env:   PODMAN_PATH (absolute podman binary; the CI podman when unset)

ADMIN_URL="${ADMIN_URL:-}"
APISIX_YAML="${APISIX_YAML:-conf/apisix.yaml}"
MANAGED_ROUTE_PREFIX="${MANAGED_ROUTE_PREFIX:-relay-}"
ADMIN_KEY_FILE="${ADMIN_KEY_FILE:-}"
PODMAN_PATH="${PODMAN_PATH:?PODMAN_PATH must be set (the repo Makefile exports it)}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --admin-key) export ADMIN_KEY="$2"; shift 2 ;;
    --admin-key-file) ADMIN_KEY_FILE="$2"; shift 2 ;;
    --admin-url) ADMIN_URL="$2"; shift 2 ;;
    --admin-exec) ADMIN_EXEC="$2"; shift 2 ;;
    --apisix-yaml) APISIX_YAML="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;  esac
done

if [ -n "$ADMIN_KEY_FILE" ] && [ -r "$ADMIN_KEY_FILE" ]; then
  ADMIN_KEY="$(<"$ADMIN_KEY_FILE")"
  export ADMIN_KEY
fi

if [ -z "${ADMIN_KEY:-}" ]; then
  echo "ERROR: ADMIN_KEY environment variable is required (set in .env, see .env.example)" >&2
  exit 1
fi

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
  _SELF="$SHG_SCRIPT_PATH"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
if [ ! -x "$SCRIPT_DIR/gateway-compose.sh" ]; then
  echo "ERROR: cannot locate gateway-compose.sh next to seed-routes.sh" >&2
  exit 1
fi
GW_WRAPPER="$SCRIPT_DIR/gateway-compose.sh"
export PODMAN_PATH

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# admin_http METHOD PATH [JSON_BODY] -> response body on stdout
admin_http() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS --max-time 10 -X "$method" -H "X-API-KEY: $ADMIN_KEY")
  if [ -n "$body" ]; then
    args+=(-H 'Content-Type: application/json' -d "$body")
  fi
  if [ -n "$ADMIN_URL" ]; then
    curl "${args[@]}" "${ADMIN_URL}${path}" </dev/null
  elif [ -n "${ADMIN_EXEC:-}" ]; then
    "$PODMAN_PATH" exec "$ADMIN_EXEC" curl "${args[@]}" "http://127.0.0.1:9180${path}" </dev/null
  else
    "$GW_WRAPPER" exec apisix -- curl "${args[@]}" "http://127.0.0.1:9180${path}" </dev/null
  fi
}

# Phase 1: parse YAML into JSON (host-side parsing; HTTP goes
# through the wrapper above).
PYTHON="uv run --with pyyaml python"
# shellcheck disable=SC2086  # PYTHON is a wrapper command line, intentionally word-split
$PYTHON -u -c "
import json, os, sys, yaml

apisix_yaml = os.environ.get('APISIX_YAML', '$APISIX_YAML')
if not os.path.exists(apisix_yaml):
    print(f'ERROR: {apisix_yaml} not found', file=sys.stderr)
    sys.exit(1)

with open(apisix_yaml) as f:
    data = yaml.safe_load(f)

if not data or 'routes' not in data:
    print('No routes found in ' + apisix_yaml)
    sys.exit(0)

routes = data['routes']
missing_ids = [route for route in routes if not route.get('id')]
if missing_ids:
    print(f'FAIL routes without ids: {len(missing_ids)}', file=sys.stderr)
    sys.exit(1)

with open('$TMPD/routes.json', 'w') as f:
    json.dump(routes, f)
print(f'Found {len(routes)} route(s) to seed')
"

# Fail before mutating etcd when APISIX has not loaded the custom plugins
# that route definitions require. HTTP readiness alone is not sufficient.
REQUIRED_PLUGIN_RE='^(key-resolver|key-meta|oauth-auth|provider-sync|redact|sse-usage)$'
export REQUIRED_PLUGIN_RE
required_plugins="$(jq -r '[.[] | .plugins // {} | keys[]] | unique | map(select(test(env.REQUIRED_PLUGIN_RE))) | join(" ")' "$TMPD/routes.json")"

loaded_plugins="$(admin_http GET /apisix/admin/plugins/list | jq -r 'if type == "array" then join(" ") else empty end')"
if [ -z "$loaded_plugins" ]; then
  echo 'FAIL plugin registry check: no plugin list from Admin API' >&2
  exit 1
fi
missing_plugins="$(jq -nr --arg req "$required_plugins" --arg loaded "$loaded_plugins" \
  '($loaded | split(" ") | map(select(length > 0))) as $L
   | ($req | split(" ") | map(select(length > 0))) - $L | join(" ")')"
if [ -n "$missing_plugins" ]; then
  echo "FAIL missing APISIX plugins: $missing_plugins" >&2
  exit 1
fi
echo "APISIX plugin registry verified ($(printf '%s' "$required_plugins" | wc -w) route plugins)"

# Reconcile only routes owned by this gateway. The prefix prevents this tool
# from deleting unrelated routes in a shared APISIX instance.
admin_http GET /apisix/admin/routes > "$TMPD/listing.json"
jq -r --arg prefix "$MANAGED_ROUTE_PREFIX" \
  '.list[]?.key | split("/") | last | select(startswith($prefix))' \
  "$TMPD/listing.json" > "$TMPD/existing_prefixed.txt"
desired_ids="$(jq -r '[.[] | .id | tostring] | join("\n")' "$TMPD/routes.json")"

while read -r route_id; do
  [ -n "$route_id" ] || continue
  if printf '%s\n' "$desired_ids" | grep -qxF "$route_id"; then
    continue
  fi
  delete_resp="$(admin_http DELETE "/apisix/admin/routes/$route_id")"
  echo "  OK   stale route $route_id deleted ($delete_resp)"
done < "$TMPD/existing_prefixed.txt"

# PUT each route (idempotent)
jq -c '.[]' "$TMPD/routes.json" | while read -r route_json; do
  rid="$(printf '%s' "$route_json" | jq -r '.id | tostring')"
  result="$(admin_http PUT "/apisix/admin/routes/$rid" "$route_json")"
  status="$(printf '%s' "$result" | jq -r '.status // "?"')"
  echo "  OK   route $rid seeded (status=$status)"
done

# Verify the exact managed route set
admin_http GET /apisix/admin/routes > "$TMPD/verify.json"
actual_managed_ids="$(jq -r --arg prefix "$MANAGED_ROUTE_PREFIX" --arg desired "$desired_ids" \
  '[.list[]?.key | split("/") | last | select(startswith($prefix) or ($desired | split("\n") | index(.)))] | sort | join("\n")' \
  "$TMPD/verify.json")"
expected_sorted="$(printf '%s\n' "$desired_ids" | sort)"
if [ "$actual_managed_ids" != "$expected_sorted" ]; then
  echo "FAIL route set mismatch: expected [$expected_sorted] got [$actual_managed_ids]" >&2
  exit 1
fi
echo 'Verified exact managed route set'
echo 'Done: all routes seeded successfully'
