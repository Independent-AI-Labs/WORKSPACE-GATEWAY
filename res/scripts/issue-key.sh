#!/bin/bash
set -euo pipefail

# issue-key.sh
# Issues a new virtual gateway key and stores it in OpenBao.
#
# Usage:
#   make issue-key
#   make issue-key KEY_ID=my-key TENANT_ID=acme USER_ID=alice
#   bash res/scripts/issue-key.sh [--key-id ID] [--tenant ID] [--user ID] [--upstream-key KEY]
#
# Options:
#   --key-id ID         Key identifier (default: vgw-<random hex>)
#   --tenant ID         Tenant ID (default: default)
#   --user ID           User ID (default: agent)
#   --upstream-key KEY  Upstream API key (default: empty = use OPENCODE_ZEN_API_KEY env)

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"

if [ -f "$ENV_FILE" ]; then
  set -a
  source "$ENV_FILE" || exit 1
  set +a
fi

OPENBAO_TOKEN="${OPENBAO_TOKEN:-2e22c6e00b0815bcada90dfecb03f3c0}"
OPENBAO_ADDR="${OPENBAO_ADDR:-http://localhost:8201}"

KEY_ID=""
TENANT_ID="default"
USER_ID="agent"
UPSTREAM_KEY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --key-id)       KEY_ID="$2"; shift 2 ;;
    --tenant)       TENANT_ID="$2"; shift 2 ;;
    --user)         USER_ID="$2"; shift 2 ;;
    --upstream-key) UPSTREAM_KEY="$2"; shift 2 ;;
    *) echo "ERROR: unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$KEY_ID" ]; then
  if RAND_HEX=$(openssl rand -hex 16); then
    :
  else
    echo "WARN: openssl rand failed, using /dev/urandom" >&2
    RAND_HEX=$(head -c 16 /dev/urandom | xxd -p)
  fi
  KEY_ID="vgw-${RAND_HEX}"
fi

CREATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

JSON_PAYLOAD=$(cat <<EOF
{"data":{"virtual_key":"${KEY_ID}","upstream_key":"${UPSTREAM_KEY}","tenant_id":"${TENANT_ID}","user_id":"${USER_ID}","active":true,"created_at":"${CREATED_AT}"}}
EOF
)

echo "=== Issuing new gateway key ==="
echo "  Key ID:   $KEY_ID"
echo "  Tenant:   $TENANT_ID"
echo "  User:     $USER_ID"
echo "  OpenBao:  $OPENBAO_ADDR"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST \
  -H "X-Vault-Token: ${OPENBAO_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$JSON_PAYLOAD" \
  "${OPENBAO_ADDR}/v1/secret/data/gateway/keys/${KEY_ID}")

if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "204" ]; then
  echo "ERROR: OpenBao write failed with HTTP $HTTP_CODE" >&2
  exit 1
fi

echo ""
echo "=== Key issued successfully ==="
echo "  Use this key in Authorization header: Bearer ${KEY_ID}"
echo ""
echo "  To use with opencode, set:"
echo "    provider.options.apiKey = \"${KEY_ID}\""
