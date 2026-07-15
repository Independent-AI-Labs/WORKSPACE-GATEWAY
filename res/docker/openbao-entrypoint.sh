#!/bin/bash
set -euo pipefail

# ─── OpenBao auto-init, auto-unseal, auto-provision entrypoint ───────────────
# Replaces dev mode (-dev) with production file-storage mode so data survives
# container restarts.  On first start it initialises with a single unseal key,
# creates a fixed-ID token (matching OPENBAO_TOKEN from .env) for external
# services like APISIX, and provisions the gateway virtual key.  On subsequent
# starts it loads saved bootstrap keys, unseals, and skips already-provisioned
# data.

export BAO_ADDR="http://127.0.0.1:8200"

BAO_DATA="/openbao/data"
KEYS_DIR="${BAO_DATA}/.bootstrap"
EXPECTED_TOKEN="${OPENBAO_TOKEN:-2e22c6e00b0815bcada90dfecb03f3c0}"
GATEWAY_SECRET="secret/gateway/keys/vgw-gateway-key"

mkdir -p "$BAO_DATA" "$KEYS_DIR"

bao_api_ready() {
    local hc
    hc=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "${BAO_ADDR}/v1/sys/health")
    case "$hc" in
        200|429|501|503) return 0 ;;
        *)
            echo "[openbao] WARN: health check HTTP $hc" >&2
            return 1
            ;;
    esac
}

bao_seal_status_json() {
    curl -sS --connect-timeout 2 "${BAO_ADDR}/v1/sys/seal-status"
}

# ─── 1. Start OpenBao server (background) ────────────────────────────────────
bao server -config=/openbao/config/openbao.hcl &
BAO_PID=$!

# ─── 2. Wait for API to respond ──────────────────────────────────────────────
# /v1/sys/health returns 200/429/501/503 once the HTTP listener is up.
echo "[openbao] Waiting for API..."
for i in $(seq 1 60); do
    if bao_api_ready; then
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "[openbao] FATAL: API not responding after 60s"
        exit 1
    fi
    sleep 1
done
echo "[openbao] API is reachable."

# ─── 3. Initialise on first start, load saved keys on restart ───────────────
INIT_JSON="$(bao_seal_status_json)"
INIT_STATUS="$(echo "$INIT_JSON" | jq -r '.initialized // false')"

if [ "$INIT_STATUS" = "false" ]; then
    echo "[openbao] First start: initialising with single unseal key..."
    INIT_OUTPUT="$(bao operator init -key-shares=1 -key-threshold=1 -format=json)"
    UNSEAL_KEY="$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[0]')"
    ROOT_TOKEN="$(echo "$INIT_OUTPUT" | jq -r '.root_token')"
    printf '%s' "$UNSEAL_KEY" > "${KEYS_DIR}/unseal-key"
    printf '%s' "$ROOT_TOKEN" > "${KEYS_DIR}/root-token"
    chmod 600 "${KEYS_DIR}/unseal-key" "${KEYS_DIR}/root-token"
    echo "[openbao] Initialised.  Bootstrap keys persisted to ${KEYS_DIR}"
else
    UNSEAL_KEY="$(cat "${KEYS_DIR}/unseal-key")"
    ROOT_TOKEN="$(cat "${KEYS_DIR}/root-token")"
    echo "[openbao] Already initialised.  Loaded bootstrap keys from volume."
fi

# ─── 4. Unseal if sealed ─────────────────────────────────────────────────────
SEAL_JSON="$(bao_seal_status_json)"
SEALED="$(echo "$SEAL_JSON" | jq -r '.sealed // true')"
if [ "$SEALED" = "true" ]; then
    echo "[openbao] Unsealing..."
    bao operator unseal "$UNSEAL_KEY" >/dev/null
    echo "[openbao] Unsealed."
fi

# ─── 5. Authenticate as root ─────────────────────────────────────────────────
export BAO_TOKEN="$ROOT_TOKEN"

# ─── 6. Enable KV v2 at secret/ if not already mounted ───────────────────────
if bao secrets list -format=json | jq -e '."secret/"' >/dev/null 2>&1; then
    echo "[openbao] KV v2 already mounted at secret/."
else
    echo "[openbao] Enabling KV v2 at secret/..."
    bao secrets enable -path=secret -version=2 kv
fi

# ─── 7. Create fixed-ID token for external services (APISIX key-resolver) ────
# The token ID matches OPENBAO_TOKEN from .env so APISIX can use it directly
# without needing to discover the random root token.
if bao token lookup "$EXPECTED_TOKEN" >/dev/null 2>&1; then
    echo "[openbao] Service token already exists (${EXPECTED_TOKEN:0:8}...)."
else
    echo "[openbao] Creating fixed-ID service token..."
    bao token create -id="$EXPECTED_TOKEN" -policy=root -ttl=0 -orphan >/dev/null
    echo "[openbao] Service token created (${EXPECTED_TOKEN:0:8}...)."
fi

# ─── 8. Provision gateway virtual key (idempotent) ───────────────────────────
if bao kv get "$GATEWAY_SECRET" >/dev/null 2>&1; then
    echo "[openbao] Gateway key already provisioned."
else
    UPSTREAM_KEY="${OPENCODE_API_KEY:-}"
    if [ -z "$UPSTREAM_KEY" ]; then
        echo "[openbao] WARNING: OPENCODE_API_KEY not set : skipping provisioning"
    else
        echo "[openbao] Provisioning gateway virtual key..."
        bao kv put "$GATEWAY_SECRET" \
            virtual_key="vgw-gateway-key" \
            upstream_key="$UPSTREAM_KEY" \
            tenant_id="default" \
            user_id="agent" \
            active=true \
            created_at="2026-01-01T00:00:00Z" \
            rate_limit_rpm=100 \
            rate_limit_window=60 \
            token_budget=1000000 \
            cost_budget=0 \
            budget_window=86400 \
            budget_type="tokens"
        echo "[openbao] Gateway key provisioned."
    fi
fi

echo "[openbao] Ready : serving on :8200"

# ─── 9. Wait for server process ──────────────────────────────────────────────
wait "$BAO_PID"
