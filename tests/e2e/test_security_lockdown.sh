#!/bin/bash
set -euo pipefail

# LIVE lockdown verification matrix (REQ-SECURITY-HARDENING verification
# matrix). Runs against the running dev stack (and prod if up). Exit 0 =
# every check passes. Requires .env for credentials.
#
#   make gw-security-matrix

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
    _SELF="$SHG_SCRIPT_PATH"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

export REPO_ROOT
# shellcheck source=../../res/scripts/lib-sql.sh
source "$REPO_ROOT/res/scripts/lib-sql.sh" || exit 1

pass=0
fail=0

ok()   { echo "[PASS] $1"; pass=$((pass + 1)); }
bad()  { echo "[FAIL] $1"; fail=$((fail + 1)); }

summary() {
    echo ""
    echo "test_security_lockdown.sh: $pass passed, $fail failed"
    [ "$fail" -eq 0 ]
}

if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    if ! source "$REPO_ROOT/.env"; then
        echo "ERROR: failed to load environment from $REPO_ROOT/.env" >&2
        exit 2
    fi
    set +a
fi

for v in CLICKHOUSE_PASSWORD CH_OPS_PASSWORD CH_GRAFANA_RO_PASSWORD \
         CH_VECTOR_PASSWORD ETCD_ROOT_PASSWORD; do
    [ -n "${!v:-}" ] || { echo "ERROR: $v not set (source repo .env)" >&2; exit 2; }
done

# ── 1. Host port surface ──────────────────────────────────────────────────
# Public data plane only; loopback CH/Grafana; every debug port closed.
expect_port() {
    # expect_port DESC HOST PORT expect(open|closed) - TCP reachability probe.
    local desc="$1" host="$2" port="$3" want="$4"
    if curl -sS -o /dev/null --connect-timeout 2 "http://$host:$port/"; then
        if [ "$want" = "open" ]; then ok "$desc (open)"; else bad "$desc: expected closed, connection succeeded"; fi
    else
        if [ "$want" = "closed" ]; then ok "$desc (closed)"; else bad "$desc: expected open, connection refused/timeout"; fi
    fi
}

expect_port "dev data plane 9080"        0.0.0.0 9080 open
expect_port "dev data plane TLS 9443"    0.0.0.0 9443 open
expect_port "loopback ClickHouse 8123"   127.0.0.1 8123 open
expect_port "loopback Grafana 3030"      127.0.0.1 3030 open

expect_port "loopback apisix Admin API/Dashboard UI 9180" 127.0.0.1 9180 open
# Admin UI must stay off the external interface: probe a non-loopback,
# non-podman-bridge host IP.
host_ip=""
for _ip in $(hostname -I); do
    case "$_ip" in
        127.*|10.99.*) ;;
        *) host_ip="$_ip"; break ;;
    esac
done
if [ -n "$host_ip" ]; then
    expect_port "apisix admin 9180 off external interface" "$host_ip" 9180 closed
fi
expect_port "apisix metrics 9100 unpublished"    0.0.0.0 9100 closed
expect_port "prometheus 9092 unpublished"        0.0.0.0 9092 closed
expect_port "etcd 2379 unpublished"              0.0.0.0 2379 closed
expect_port "openbao 8201 unpublished"           0.0.0.0 8201 closed
expect_port "vector 18080 unpublished"           0.0.0.0 18080 closed
expect_port "ClickHouse native 9000 unpublished" 0.0.0.0 9000 closed

# ── 2. ClickHouse auth matrix (via loopback 8123; host-forwarded) ─────────
ch_post() { curl -sS --max-time 5 -o /tmp/gw-sec-ch.out -w '%{http_code}' http://127.0.0.1:8123/ "$@"; }

code=$(ch_post --user "ops_admin:$CH_OPS_PASSWORD" --data-binary 'SELECT 1')
[ "$code" = "200" ] && ok "ops_admin can query" || bad "ops_admin query: HTTP $code $(cat /tmp/gw-sec-ch.out)"

code=$(ch_post --user "grafana_ro:$CH_GRAFANA_RO_PASSWORD" --data-binary "$(sql_render tests/security-lockdown/count-request-log.sql)")
[ "$code" = "200" ] && ok "grafana_ro reads metadata" || bad "grafana_ro metadata read: HTTP $code $(cat /tmp/gw-sec-ch.out)"

code=$(ch_post --user "grafana_ro:$CH_GRAFANA_RO_PASSWORD" --data-binary "$(sql_render tests/security-lockdown/count-request-bodies.sql)")
[ "$code" != "200" ] && ok "grafana_ro CANNOT read request_bodies" || bad "grafana_ro read request_bodies: HTTP $code - GRANT LEAK"

code=$(ch_post --user "vector_rw:$CH_VECTOR_PASSWORD" --data-binary "$(sql_render tests/security-lockdown/count-request-log.sql)")
[ "$code" != "200" ] && ok "vector_rw CANNOT SELECT" || bad "vector_rw SELECT: HTTP $code - GRANT LEAK"

code=$(ch_post --user "vector_rw:$CH_VECTOR_PASSWORD" --data-binary "$(sql_render tests/security-lockdown/insert-body-probe.sql)")
[ "$code" = "200" ] && ok "vector_rw can INSERT bodies" || bad "vector_rw insert bodies: HTTP $code $(cat /tmp/gw-sec-ch.out)"
code=$(ch_post --user "ops_admin:$CH_OPS_PASSWORD" --data-binary "$(sql_render tests/security-lockdown/delete-body-probe.sql)")
[ "$code" = "200" ] && ok "probe row cleaned up" || bad "probe cleanup: HTTP $code"

code=$(ch_post --data-binary 'SELECT 1')
[ "$code" != "200" ] && ok "unauthenticated ClickHouse rejected ($code)" || bad "unauthenticated ClickHouse: HTTP 200 - OPEN DATABASE"

# `default` must be unusable from a non-localhost source. Host loopback
# forwards can appear as container-localhost under pasta, so probe from the
# apisix container (source 10.99.10.2) through the exec harness.
PODMAN="${PODMAN:-podman}"
probe_out="$($PODMAN exec docker_apisix_1 curl -sS --max-time 5 \
    -u "default:$CLICKHOUSE_PASSWORD" --data-binary 'SELECT 1' \
    http://clickhouse:8123/ )"
case "$probe_out" in
    *AUTHENTICATION_FAILED*|*"Authentication failed"*)
        ok "default rejected from non-localhost container source" ;;
    "")
        bad "default probe: no response from apisix container" ;;
    *)
        bad "default accepted from apisix container: $probe_out" ;;
esac

# ── 3. Grafana hardening ───────────────────────────────────────────────────
graf_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
    -H 'X-WEBAUTH-USER: attacker' http://127.0.0.1:3030/api/user)
[ "$graf_code" != "200" ] \
    && ok "spoofed X-WEBAUTH-USER rejected from non-edge source" \
    || bad "auth-proxy honored X-WEBAUTH-USER from loopback (check GF_AUTH_PROXY_WHITELIST)"

# ── 4. etcd RBAC (exec-based; port unpublished) ────────────────────────────
PODMAN="${PODMAN:-podman}"
if $PODMAN exec gw-etcd etcdctl get / --prefix --limit=1 >/tmp/gw-sec-etcd.out 2>&1; then
    bad "etcd answers UNAUTHENTICATED reads (RBAC not enabled - run make etcd-auth-init)"
else
    ok "etcd rejects unauthenticated reads"
fi
if $PODMAN exec gw-etcd etcdctl --user "root:$ETCD_ROOT_PASSWORD" endpoint health >/tmp/gw-sec-etcd2.out 2>&1; then
    ok "etcd root credentials valid"
else
    bad "etcd root credentials invalid: $(cat /tmp/gw-sec-etcd2.out)"
fi

# ── 5. Prod data plane (if running) ────────────────────────────────────────
if curl -sS -o /dev/null --connect-timeout 2 http://0.0.0.0:9081/ && [ "$?" = "0" ]; then
    expect_port "prod data plane 9081" 0.0.0.0 9081 open
    expect_port "prod admin 9181 unpublished" 0.0.0.0 9181 closed
else
    echo "[SKIP] prod stack not running (9081)"
fi

summary
