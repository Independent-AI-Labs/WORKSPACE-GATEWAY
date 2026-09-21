#!/bin/bash
set -euo pipefail

# etcd RBAC bootstrap (REQ-SECURITY-HARDENING FR-6). Enables authentication
# with a root account and a least-privilege apisix user scoped to the
# /apisix/ prefix. Runs etcdctl inside the gw-etcd container (port 2379 is
# not published). Idempotent: safe when auth is already enabled.
#
# Creds come from the repo .env: ETCD_ROOT_PASSWORD, ETCD_GW_USER,
# ETCD_GW_PASSWORD. After the first enable, restart apisix so it reconnects
# with credentials (RUNBOOK-DEPLOYMENT).

fail() { echo "[etcd-auth-init] ERROR: $*" >&2; exit 1; }

CONTAINER="${ETCD_CONTAINER:-gw-etcd}"
PODMAN="${PODMAN:-podman}"

for v in ETCD_ROOT_PASSWORD ETCD_GW_USER ETCD_GW_PASSWORD; do
    [ -n "${!v:-}" ] || fail "required env $v not set (source repo .env)"
done

ectl() {
    "$PODMAN" exec "$CONTAINER" etcdctl \
        --command-timeout=10s "$@"
}

ectl_root() {
    "$PODMAN" exec "$CONTAINER" etcdctl \
        --user "root:${ETCD_ROOT_PASSWORD}" \
        --command-timeout=10s "$@"
}

user_exists() {
    # "$1" = username; caller supplies auth context via ectl/ectl_root
    ectl user list | grep -qx "$1"
}

auth_enabled() {
    # `auth status` itself requires credentials once auth is on, and root
    # credentials are ignored while it is off - so one authenticated call
    # answers both states.
    ectl_root auth status | grep -q 'Authentication Status: true'
}

ensure_users() {
    # "$1" = etcdctl wrapper (ectl for unauthenticated bootstrap,
    # ectl_root once auth is enabled). All steps idempotent.
    local e="$1"
    # grant-role fails with "already granted" when reapplied; treat only
    # that specific outcome as success and surface everything else.
    grant_role() {
        # shellcheck disable=SC2155 # small helper, globals are fine here
        errf="$(mktemp)"
        if "$e" user grant-role "$1" "$2" 2>"$errf"; then
            rm -f "$errf"
            return 0
        fi
        grant_role_rc=$?
        grant_role_out="$(cat "$errf")"
        rm -f "$errf"
        case "$grant_role_out" in
            *"already granted"*) return 0 ;;
        esac
        printf '%s\n' "$grant_role_out" >&2
        return "$grant_role_rc"
    }
    if ! "$e" user list | grep -qx "root"; then
        "$e" user add "root:${ETCD_ROOT_PASSWORD}"
    fi
    grant_role root root
    if ! "$e" user list | grep -qx "apisix"; then
        "$e" user add "apisix:${ETCD_GW_PASSWORD}"
    fi
    if ! "$e" role list | grep -qx "apisix-route"; then
        "$e" role add apisix-route
    fi
    "$e" role grant-permission apisix-route --prefix=true readwrite /apisix/
    grant_role apisix apisix-route
}

if auth_enabled; then
    ensure_users ectl_root
    echo "[etcd-auth-init] auth already enabled; apisix user/role verified"
    exit 0
fi

# Auth not yet enabled: unauthenticated calls are allowed.
ensure_users ectl
ectl auth enable

ectl_root endpoint health
echo "[etcd-auth-init] RBAC enabled: root + apisix (prefix /apisix/); restart apisix to reconnect with credentials"
