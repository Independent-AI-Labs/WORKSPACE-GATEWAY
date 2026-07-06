#!/bin/bash
set -euo pipefail

# list-keys.sh
# Lists all virtual gateway keys stored in OpenBao.
#
# Usage:
#   make list-keys
#   bash res/scripts/list-keys.sh

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"

if [ -f "$ENV_FILE" ]; then
  set -a
  source "$ENV_FILE" || exit 1
  set +a
fi

OPENBAO_TOKEN="${OPENBAO_TOKEN:-2e22c6e00b0815bcada90dfecb03f3c0}"
OPENBAO_ADDR="${OPENBAO_ADDR:-http://localhost:8201}"

echo "=== Listing gateway keys from OpenBao ==="
echo "  OpenBao: $OPENBAO_ADDR"
echo ""

KEY_LISTING=$(curl -sf \
  -H "X-Vault-Token: ${OPENBAO_TOKEN}" \
  -X LIST \
  "${OPENBAO_ADDR}/v1/secret/metadata/gateway/keys/") || {
  echo "  No keys found (or OpenBao not reachable: curl exit $?)." >&2
  exit 0
}

KEYS=$(echo "$KEY_LISTING" | jq -r '.data.keys[]?') || {
  echo "  No keys found (jq parse error)." >&2
  exit 0
}

if [ -z "$KEYS" ]; then
  echo "  No keys found."
  exit 0
fi

printf "%-40s %-12s %-12s %-8s %-20s\n" "KEY_ID" "TENANT" "USER" "ACTIVE" "CREATED"
printf "%-40s %-12s %-12s %-8s %-20s\n" "----------------------------------------" "------------" "------------" "--------" "--------------------"

for KEY_ID in $KEYS; do
  KEY_DATA=$(curl -sf \
    -H "X-Vault-Token: ${OPENBAO_TOKEN}" \
    "${OPENBAO_ADDR}/v1/secret/data/gateway/keys/${KEY_ID}") || {
    echo "  WARN: failed to fetch data for ${KEY_ID}: curl exit $?" >&2
    continue
  }

  if [ -n "$KEY_DATA" ]; then
    TENANT=$(echo "$KEY_DATA" | jq -r '.data.data.tenant_id // ""')
    USER=$(echo "$KEY_DATA" | jq -r '.data.data.user_id // ""')
    ACTIVE=$(echo "$KEY_DATA" | jq -r '.data.data.active // false')
    CREATED=$(echo "$KEY_DATA" | jq -r '.data.data.created_at // ""')
    printf "%-40s %-12s %-12s %-8s %-20s\n" "$KEY_ID" "$TENANT" "$USER" "$ACTIVE" "$CREATED"
  fi
done
