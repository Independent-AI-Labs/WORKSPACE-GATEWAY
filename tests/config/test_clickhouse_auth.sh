#!/bin/bash
set -euo pipefail

# Static auth-posture tests for ClickHouse hardening
# (REQ-SECURITY-HARDENING FR-1/FR-2/FR-3).
_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
    _SELF="$SHG_SCRIPT_PATH"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass=0
fail=0

assert_eq() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "[PASS] $desc"
        pass=$((pass + 1))
    else
        echo "[FAIL] $desc -- expected: $expected, actual: $actual"
        fail=$((fail + 1))
    fi
}

summary() {
    echo ""
    echo "test_clickhouse_auth.sh: $pass passed, $fail failed"
    if [ "$fail" -gt 0 ]; then
        exit 1
    fi
}

PROVISION="$REPO_ROOT/res/docker/clickhouse-provision.sh"
OPS_ADMIN_XML="$REPO_ROOT/conf/clickhouse-users.d/ops-admin.xml"
TIERING_XML="$REPO_ROOT/conf/clickhouse-storage-tiering.xml"
DATASOURCES="$REPO_ROOT/conf/grafana/provisioning/datasources/datasources.yml"
ENV_EXAMPLE="$REPO_ROOT/.env.example"

provision_rc=0
PROVISION_BODY="$(cat "$PROVISION")" || provision_rc=$?
assert_eq "provision script exists" "0" "$provision_rc"

# ── grafana_ro: read-only metadata, NEVER bodies ──────────────────────────
assert_eq "grafana_ro is readonly" "1" \
    "$(printf '%s' "$PROVISION_BODY" | grep -c 'readonly = 1, allow_ddl = 0')"
assert_eq "grafana_ro SELECT on llm_gateway.*" "1" \
    "$(printf '%s' "$PROVISION_BODY" | grep -c 'GRANT SELECT ON llm_gateway.\*')"
assert_eq "no grant gives grafana_ro access to request_bodies" "0" \
    "$(printf '%s' "$PROVISION_BODY" | grep -c 'grafana_ro.*request_bodies')"
assert_eq "grafana_ro can read growth-panel system tables" "1" \
    "$(printf '%s' "$PROVISION_BODY" | grep -c 'GRANT SELECT ON system.parts TO grafana_ro')"
assert_eq "grafana_ro grant on request_bodies is explicitly revoked (db-wide grant would cover it)" "1" \
    "$(printf '%s' "$PROVISION_BODY" | grep -c 'REVOKE SELECT ON llm_gateway.request_bodies FROM grafana_ro')"

# ── least-privilege writers ───────────────────────────────────────────────
assert_eq "vector_rw INSERT-only on request_log + request_bodies" "1" \
    "$(printf '%s' "$PROVISION_BODY" | grep -c 'GRANT INSERT ON llm_gateway.request_bodies')"
assert_eq "apisix_rw INSERT-only on usage_log" "1" \
    "$(printf '%s' "$PROVISION_BODY" | grep -c 'GRANT INSERT ON llm_gateway.usage_log')"
assert_eq "migrator scoped to llm_gateway.*" "1" \
    "$(printf '%s' "$PROVISION_BODY" | grep -c 'GRANT ALL ON llm_gateway.\*')"
# `default` locked to localhost via users.d override (users.xml is readonly
# for ALTER at runtime), not via the provision script.
DEFAULT_LOCAL_XML="$REPO_ROOT/conf/clickhouse-users.d/default-local.xml"
dl_rc=0
DL_BODY="$(cat "$DEFAULT_LOCAL_XML")" || dl_rc=$?
assert_eq "default-local.xml exists" "0" "$dl_rc"
assert_eq "default restricted to loopback via users.d override" "1" \
    "$(printf '%s' "$DL_BODY" | grep -c '<ip>127.0.0.1</ip>')"
assert_eq "default override has no wildcard host" "0" \
    "$(printf '%s' "$DL_BODY" | grep -c '::/0')"

# ── ops_admin: XML-defined bootstrap admin, default never has access mgmt ──
xml_rc=0
XML_BODY="$(cat "$OPS_ADMIN_XML")" || xml_rc=$?
assert_eq "ops-admin.xml exists" "0" "$xml_rc"
assert_eq "ops_admin password from env (no hardcoded secret)" "1" \
    "$(printf '%s' "$XML_BODY" | grep -c 'from_env="CH_OPS_PASSWORD"')"
assert_eq "ops_admin has access_management" "1" \
    "$(printf '%s' "$XML_BODY" | grep -c '<access_management>1</access_management>')"
assert_eq "ops_admin restricted to loopback + stack gateways" "1" \
    "$(printf '%s' "$XML_BODY" | grep -c '<ip>10.99.10.1</ip>')"
assert_eq "no wildcard host for ops_admin" "0" \
    "$(printf '%s' "$XML_BODY" | grep -c '<ip>0.0.0.0/0</ip>')"

# ── Grafana datasource identity ───────────────────────────────────────────
ds_rc=0
DS_BODY="$(cat "$DATASOURCES")" || ds_rc=$?
assert_eq "datasources.yml exists" "0" "$ds_rc"
assert_eq "datasource user is grafana_ro (not default)" "1" \
    "$(printf '%s' "$DS_BODY" | grep -c 'username: grafana_ro')"
assert_eq "datasource password from secureJsonData env" "1" \
    "$(printf '%s' "$DS_BODY" | grep -c 'password: \${CH_GRAFANA_RO_PASSWORD}')"
assert_eq "datasource never uses passwordless default" "0" \
    "$(printf '%s' "$DS_BODY" | grep -c 'username: default')"

# ── storage tiering config ────────────────────────────────────────────────
tier_rc=0
TIER_BODY="$(cat "$TIERING_XML")" || tier_rc=$?
assert_eq "storage-tiering.xml exists" "0" "$tier_rc"
assert_eq "archive disk under the data volume (comment + config)" "2" \
    "$(printf '%s' "$TIER_BODY" | grep -c '/var/lib/clickhouse/arch_store/')"
assert_eq "tiered policy has hot + archive volumes" "1" \
    "$(printf '%s' "$TIER_BODY" | grep -c '<tiered>')"
assert_eq "backups disk declared for nightly BACKUP" "1" \
    "$(printf '%s' "$TIER_BODY" | grep -c '<path>/var/lib/clickhouse/backups/</path>')"
assert_eq "Disk backup engine allows the backups disk (24.8 config gate)" "1" \
    "$(printf '%s' "$TIER_BODY" | grep -c '<allowed_disk>backups</allowed_disk>')"
assert_eq "no live disk path points at ws-backup" "0" \
    "$(printf '%s' "$TIER_BODY" | grep -c '<path>.*ws-backup')"
assert_eq "implicit default disk is NOT redefined under <disks> (CH 24.8 fatal)" "0" \
    "$(printf '%s' "$TIER_BODY" | grep -c '<path>/var/lib/clickhouse/</path>')"
# system.backups.name is the full spec Disk('backups', '<name>'), so the
# nightly backup must match by substring or it never sees its own backup.
assert_eq "nightly backup matches system.backups.name by substring" "1" \
    "$(grep -c "position(name, '\${NAME}')" "$REPO_ROOT/res/scripts/gateway-ch-backup.sh")"
# system.backups is a non-persistent SystemBackups view: it rejects mutations,
# so the failed-backup cleanup must remove the directory, never ALTER DELETE.
assert_eq "failed-backup cleanup does not mutate system.backups" "0" \
    "$(grep -c "ALTER TABLE system.backups DELETE" "$REPO_ROOT/res/scripts/gateway-ch-backup.sh")"

# ── core-utilisation tuning (32-core host) ────────────────────────────────
PERF_XML="$REPO_ROOT/conf/clickhouse-performance.xml"
PERF_USER_XML="$REPO_ROOT/conf/clickhouse-users.d/performance.xml"
perf_rc=0
PERF_BODY="$(cat "$PERF_XML")" || perf_rc=$?
assert_eq "clickhouse-performance.xml exists" "0" "$perf_rc"
assert_eq "background pool sized for all cores" "1" \
    "$(printf '%s' "$PERF_BODY" | grep -c '<background_pool_size>32</background_pool_size>')"
assert_eq "mutation free-entries threshold lowered" "1" \
    "$(printf '%s' "$PERF_BODY" | grep -c '<number_of_free_entries_in_pool_to_execute_mutation>8<')"
perf_user_rc=0
PERF_USER_BODY="$(cat "$PERF_USER_XML")" || perf_user_rc=$?
assert_eq "users.d performance.xml exists" "0" "$perf_user_rc"
assert_eq "default profile uses all cores" "1" \
    "$(printf '%s' "$PERF_USER_BODY" | grep -c '<max_threads>32</max_threads>')"
assert_eq "performance XML defines no credentials" "0" \
    "$(printf '%s' "$PERF_BODY" | grep -c 'password')"

# ── .env.example ships every credential slot ──────────────────────────────
for var in CLICKHOUSE_PASSWORD CH_OPS_PASSWORD CH_GRAFANA_RO_PASSWORD \
           CH_VECTOR_PASSWORD CH_APISIX_PASSWORD CH_MIGRATOR_PASSWORD \
           ETCD_ROOT_PASSWORD ETCD_GW_USER ETCD_GW_PASSWORD GRAFANA_EDGE_CIDR; do
    assert_eq ".env.example declares $var" "1" \
        "$(grep -c "^${var}=" "$ENV_EXAMPLE")"
done

summary
