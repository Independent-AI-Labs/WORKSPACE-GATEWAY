#!/bin/bash
set -euo pipefail

# revoke-key.sh
# Revokes a virtual gateway key by setting active=false in OpenBao.
# The key record is preserved for audit (not deleted).
#
# Usage:
#   make revoke-key KEY_ID=vgw-abc123
#   bash res/scripts/revoke-key.sh <key_id>

if [ $# -lt 1 ]; then
  echo "ERROR: key_id required" >&2
  echo "Usage: $0 <key_id>" >&2
  exit 1
fi

KEY_ID="$1"

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"

if [ -f "$ENV_FILE" ]; then
  set -a
  source "$ENV_FILE" || exit 1
  set +a
fi

OPENBAO_TOKEN="${OPENBAO_TOKEN:-2e22c6e00b0815bcada90dfecb03f3c0}"
OPENBAO_ADDR="${OPENBAO_ADDR:-http://localhost:8201}"

echo "=== Revoking gateway key ==="
echo "  Key ID:  $KEY_ID"
echo "  OpenBao: $OPENBAO_ADDR"

EXISTING=$(curl -sf \
  -H "X-Vault-Token: ${OPENBAO_TOKEN}" \
  "${OPENBAO_ADDR}/v1/secret/data/gateway/keys/${KEY_ID}") || {
  echo "ERROR: key not found or OpenBao unreachable (curl exit $?)" >&2
  exit 1
}

DATA=$(echo "$EXISTING" | jq -c '.data.data')
if [ -z "$DATA" ] || [ "$DATA" = "null" ]; then
  echo "ERROR: failed to parse key data from OpenBao" >&2
  exit 1
fi

UPDATED=$(echo "$DATA" | jq -c '. + {active: false, revoked_at: now | todateiso8601}')

JSON_PAYLOAD=$(cat <<EOF
{"data":${UPDATED}}
EOF
)

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
echo "=== Key revoked successfully ==="
echo "  Key ${KEY_ID} is now inactive (active=false)."
echo "  The key record is preserved for audit."
