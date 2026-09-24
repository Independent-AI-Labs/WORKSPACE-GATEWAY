#!/bin/bash
set -euo pipefail

# gateway-key.sh
# Unified CLI for virtual gateway keys (vgw-*) and named upstream key pools.
# A thin dispatcher over the single-purpose scripts (issue-key.sh,
# list-keys.sh, revoke-key.sh, pool-key.sh) plus two operations they do not
# cover: `show` prints one key record including its upstream mapping, and
# `map` changes that mapping on an existing key.
#
# Mapping precedence (key-resolver.lua): a non-empty upstream_pool is used
# first, then upstream_key, then the gateway-wide OPENCODE_API_KEY env.
#
# Usage:
#   gateway-key.sh issue [flags...]     Issue a key (flags forwarded to issue-key.sh)
#   gateway-key.sh list                 List keys (KEY_ID/TENANT/USER/ACTIVE/CREATED)
#   gateway-key.sh show <key_id>        Show one key record and its upstream mapping
#   gateway-key.sh map <key_id> ...     Change the upstream mapping:
#       --upstream-key KEY                Pin one upstream key (clears the pool)
#       --pool NAME                       Attach a named pool (takes precedence)
#       --none                            Clear both (use gateway OPENCODE_API_KEY)
#   gateway-key.sh revoke <key_id>      Soft-revoke a key (active=false, record kept)
#   gateway-key.sh pool <args...>       Pool ops: create/add/remove/list/enable/disable/reset
#   gateway-key.sh help                 This text
#
# Env: OPENBAO_TOKEN (required for show/map/issue/revoke/list/pool),
#      OPENBAO_ADDR, OPENBAO_CONTAINER, ENV_FILE.

_SELF="$0"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
    _SELF="$SHG_SCRIPT_PATH"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"

if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE" || exit 1
    set +a
fi

OPENBAO_ADDR="${OPENBAO_ADDR:-http://127.0.0.1:8200}"
OPENBAO_CONTAINER="${OPENBAO_CONTAINER:-gw-openbao}"

# Port 8200 is not published; reach OpenBao via podman exec (RUNBOOK-KEYS).
bao() {
    podman exec -i "$OPENBAO_CONTAINER" curl -sS -f "$@"
}

require_token() {
    : "${OPENBAO_TOKEN:?OPENBAO_TOKEN not set (source repo .env)}"
}

usage() {
    sed -n '6,27p' "$0" | sed 's/^# \{0,1\}//' >&2
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

fetch_key() {
    local kid="$1" resp data
    resp=$(bao -H "X-Vault-Token: ${OPENBAO_TOKEN}" \
        "${OPENBAO_ADDR}/v1/secret/data/gateway/keys/${kid}") \
        || die "key not found or OpenBao unreachable: ${kid}"
    data=$(printf '%s' "$resp" | jq -c '.data.data // null')
    [ "$data" != "null" ] || die "no record for key: ${kid}"
    printf '%s' "$data"
}

write_key() {
    local kid="$1" data="$2" resp
    resp=$(bao -X POST \
        -H "X-Vault-Token: ${OPENBAO_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$(jq -nc --argjson d "$data" '{data:$d}')" \
        "${OPENBAO_ADDR}/v1/secret/data/gateway/keys/${kid}") \
        || die "OpenBao write failed for key: ${kid}"
}

CMD="${1:-help}"
if [ $# -gt 0 ]; then shift; fi

case "$CMD" in
    help|-h|--help)
        usage
        ;;
    issue)
        exec "$SCRIPT_DIR/issue-key.sh" "$@"
        ;;
    list)
        exec "$SCRIPT_DIR/list-keys.sh"
        ;;
    revoke)
        KEY_ID="${1:-}"
        [ -n "$KEY_ID" ] || die "usage: gateway-key.sh revoke <key_id>"
        exec "$SCRIPT_DIR/revoke-key.sh" "$KEY_ID"
        ;;
    pool)
        [ $# -gt 0 ] || die "usage: gateway-key.sh pool <create|add|remove|list|enable|disable|reset> ..."
        exec "$SCRIPT_DIR/pool-key.sh" "$@"
        ;;
    show|describe|get)
        KEY_ID="${1:-}"
        [ -n "$KEY_ID" ] || die "usage: gateway-key.sh show <key_id>"
        require_token
        fetch_key "$KEY_ID" | jq -r '
            "key_id:        \(.virtual_key // "")",
            "tenant:        \(.tenant_id // "")",
            "user:          \(.user_id // "")",
            "active:        \(.active // false)",
            "created_at:    \(.created_at // "")",
            "revoked_at:    \(.revoked_at // "")",
            "upstream_pool: \(.upstream_pool // "")",
            "upstream_key:  \(if (.upstream_key // "") == "" then "(gateway OPENCODE_API_KEY)" else ((.upstream_key[0:4]) + "..." + (.upstream_key[-4:])) end)",
            "rate_limit:    \(.rate_limit_rpm // "") rpm / \(.rate_limit_window // "")s",
            "token_budget:  \(.token_budget // 0)",
            "cost_budget:   \(.cost_budget // 0)",
            "budget_window: \(.budget_window // 0)s",
            "budget_type:   \(.budget_type // "tokens")"
        '
        ;;
    map|mapping)
        KEY_ID="${1:-}"
        [ -n "$KEY_ID" ] || die "usage: gateway-key.sh map <key_id> (--upstream-key KEY | --pool NAME | --none)"
        shift 1
        MODE=""
        NEW_KEY=""
        NEW_POOL=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --upstream-key) NEW_KEY="${2:-}"; MODE="key"; shift $(( $# >= 2 ? 2 : 1 )) ;;
                --pool)         NEW_POOL="${2:-}"; MODE="pool"; shift $(( $# >= 2 ? 2 : 1 )) ;;
                --none)         MODE="none"; shift ;;
                *) die "unknown option: $1" ;;
            esac
        done
        [ -n "$MODE" ] || die "map needs one of --upstream-key, --pool, or --none"
        case "$MODE" in
            key)  [ -n "$NEW_KEY" ] || die "--upstream-key needs a value" ;;
            pool) [ -n "$NEW_POOL" ] || die "--pool needs a value" ;;
        esac
        require_token
        DATA=$(fetch_key "$KEY_ID")
        case "$MODE" in
            key)  DATA=$(printf '%s' "$DATA" | jq -c --arg k "$NEW_KEY" '.upstream_key = $k | .upstream_pool = ""') ;;
            pool) DATA=$(printf '%s' "$DATA" | jq -c --arg p "$NEW_POOL" '.upstream_pool = $p') ;;
            none) DATA=$(printf '%s' "$DATA" | jq -c '.upstream_key = "" | .upstream_pool = ""') ;;
        esac
        write_key "$KEY_ID" "$DATA"
        echo "=== Mapping updated: ${KEY_ID} (mode=${MODE}) ==="
        ;;
    *)
        usage
        echo "" >&2
        die "unknown command: ${CMD}"
        ;;
esac
