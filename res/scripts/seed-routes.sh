#!/usr/bin/env bash
set -euo pipefail

# seed-routes.sh
# Reads conf/apisix.yaml and seeds each route into the APISIX Admin API.
# Designed for the role switch from standalone (yaml) to traditional (etcd).
# Usage: seed-routes.sh [--admin-key <key>] [--admin-url <url>] [--apisix-yaml <path>]

ADMIN_URL="${ADMIN_URL:-http://localhost:9180}"
APISIX_YAML="${APISIX_YAML:-conf/apisix.yaml}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --admin-key) ADMIN_KEY="$2"; shift 2 ;;
    --admin-url) ADMIN_URL="$2"; shift 2 ;;
    --apisix-yaml) APISIX_YAML="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

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

for route in routes:
    rid = route.get('id')
    if not rid:
        print(f'  SKIP route with no id: {json.dumps(route, indent=2)[:100]}', file=sys.stderr)
        continue

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

print('Done: all routes seeded successfully')
"
