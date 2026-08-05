#!/usr/bin/env bash
set -euo pipefail

# seed-routes.sh
# Reads conf/apisix.yaml and seeds each route into the APISIX Admin API.
# Designed for the role switch from standalone (yaml) to traditional (etcd).
# Usage: seed-routes.sh [--admin-key <key>] [--admin-key-file <path>] [--admin-url <url>] [--apisix-yaml <path>]

ADMIN_URL="${ADMIN_URL:-http://localhost:9180}"
APISIX_YAML="${APISIX_YAML:-conf/apisix.yaml}"
MANAGED_ROUTE_PREFIX="${MANAGED_ROUTE_PREFIX:-relay-}"
ADMIN_KEY_FILE="${ADMIN_KEY_FILE:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --admin-key) export ADMIN_KEY="$2"; shift 2 ;;
    --admin-key-file) ADMIN_KEY_FILE="$2"; shift 2 ;;
    --admin-url) ADMIN_URL="$2"; shift 2 ;;
    --apisix-yaml) APISIX_YAML="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [ -n "$ADMIN_KEY_FILE" ] && [ -r "$ADMIN_KEY_FILE" ]; then
  ADMIN_KEY="$(<"$ADMIN_KEY_FILE")"
  export ADMIN_KEY
fi

if [ -z "${ADMIN_KEY:-}" ]; then
  echo "ERROR: ADMIN_KEY environment variable is required (set in .env, see .env.example)" >&2
  exit 1
fi

PYTHON=$(command -v python3 || command -v python)

exec "$PYTHON" -u -c "
import os, sys, json, urllib.request, urllib.error, yaml

admin_key = os.environ.get('ADMIN_KEY', '').strip()
if not admin_key:
    print('ERROR: ADMIN_KEY environment variable is required', file=sys.stderr)
    sys.exit(1)
admin_url = os.environ.get('ADMIN_URL', '$ADMIN_URL').rstrip('/')
apisix_yaml = os.environ.get('APISIX_YAML', '$APISIX_YAML')

if not os.path.exists(apisix_yaml):
    print(f'ERROR: {apisix_yaml} not found', file=sys.stderr)
    sys.exit(1)

with open(apisix_yaml) as f:
    data = yaml.safe_load(f)

if not data or 'routes' not in data:
    print(f'No routes found in {apisix_yaml}')
    sys.exit(0)

routes = data['routes']
print(f'Found {len(routes)} route(s) to seed')

headers = {
    'X-API-KEY': admin_key,
    'Content-Type': 'application/json',
}

# Fail before mutating etcd when APISIX has not loaded the custom plugins that
# route definitions require. HTTP readiness alone is not sufficient here.
required_plugins = {
    plugin_name
    for route in routes
    for plugin_name in (route.get('plugins') or {})
    if plugin_name in {'key-resolver', 'key-meta', 'kimi-auth', 'openai-auth',
                       'provider-sync', 'redact', 'sse-usage'}
}
plugins_req = urllib.request.Request(
    f'{admin_url}/apisix/admin/plugins/list', headers={'X-API-KEY': admin_key})
try:
    with urllib.request.urlopen(plugins_req, timeout=10) as resp:
        loaded_plugins = set(json.loads(resp.read().decode('utf-8')))
except (urllib.error.URLError, ValueError) as e:
    print(f'FAIL plugin registry check: {e}', file=sys.stderr)
    sys.exit(1)
missing_plugins = sorted(required_plugins - loaded_plugins)
if missing_plugins:
    print('FAIL missing APISIX plugins: ' + ', '.join(missing_plugins), file=sys.stderr)
    sys.exit(1)
print(f'APISIX plugin registry verified ({len(required_plugins)} route plugins)')

missing_ids = [route for route in routes if not route.get('id')]
if missing_ids:
    print(f'FAIL routes without ids: {len(missing_ids)}', file=sys.stderr)
    sys.exit(1)
desired_ids = {str(route['id']) for route in routes}
routes_req = urllib.request.Request(
    f'{admin_url}/apisix/admin/routes', headers={'X-API-KEY': admin_key})
try:
    with urllib.request.urlopen(routes_req, timeout=10) as resp:
        route_listing = json.loads(resp.read().decode('utf-8'))
except (urllib.error.URLError, ValueError) as e:
    print(f'FAIL route registry check: {e}', file=sys.stderr)
    sys.exit(1)

# Reconcile only routes owned by this gateway. The prefix prevents this tool
# from deleting unrelated routes in a shared APISIX instance.
for item in route_listing.get('list', []):
    key = str(item.get('key', ''))
    route_id = key.rsplit('/', 1)[-1]
    if route_id.startswith(os.environ.get('MANAGED_ROUTE_PREFIX', 'relay-')) and route_id not in desired_ids:
        delete_req = urllib.request.Request(
            f'{admin_url}/apisix/admin/routes/{route_id}',
            headers={'X-API-KEY': admin_key}, method='DELETE')
        try:
            with urllib.request.urlopen(delete_req, timeout=10):
                print(f'  OK   stale route {route_id} deleted')
        except urllib.error.HTTPError as e:
            print(f'  FAIL stale route {route_id} HTTP {e.code}', file=sys.stderr)
            sys.exit(1)

for route in routes:
    rid = route.get('id')
    url = f'{admin_url}/apisix/admin/routes/{rid}'

    # PUT so it's idempotent
    body = json.dumps(route).encode('utf-8')
    req = urllib.request.Request(url, data=body, headers=headers, method='PUT')

    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            result = json.loads(resp.read().decode('utf-8'))
            print(f'  OK   route {rid} seeded (status={result.get(\"status\", \"?\")})')
    except urllib.error.HTTPError as e:
        err_body = e.read().decode('utf-8', errors='replace')
        print(f'  FAIL route {rid} HTTP {e.code}: {err_body}', file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f'  FAIL route {rid} connection error: {e.reason}', file=sys.stderr)
        sys.exit(1)

verify_req = urllib.request.Request(
    f'{admin_url}/apisix/admin/routes', headers={'X-API-KEY': admin_key})
try:
    with urllib.request.urlopen(verify_req, timeout=10) as resp:
        verify_listing = json.loads(resp.read().decode('utf-8'))
except (urllib.error.URLError, ValueError) as e:
    print(f'FAIL route reconciliation verification: {e}', file=sys.stderr)
    sys.exit(1)
actual_managed_ids = {
    str(item.get('key', '')).rsplit('/', 1)[-1]
    for item in verify_listing.get('list', [])
    if str(item.get('key', '')).rsplit('/', 1)[-1].startswith(
        os.environ.get('MANAGED_ROUTE_PREFIX', 'relay-'))
    or str(item.get('key', '')).rsplit('/', 1)[-1] in desired_ids
}
if actual_managed_ids != desired_ids:
    print('FAIL route set mismatch: ' + json.dumps({
        'missing': sorted(desired_ids - actual_managed_ids),
        'unexpected': sorted(actual_managed_ids - desired_ids),
    }), file=sys.stderr)
    sys.exit(1)
print('Verified exact managed route set')

print('Done: all routes seeded successfully')
"
