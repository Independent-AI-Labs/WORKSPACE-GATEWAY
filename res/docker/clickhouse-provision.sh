#!/bin/bash
# ClickHouse user/grant provisioning (REQ-SECURITY-HARDENING FR-1/FR-2).
# Idempotent: safe on fresh volumes (docker-entrypoint-initdb.d) and via
# `make ch-provision` (podman exec) after upgrades/credential rotation.
#
# Runs as ops_admin (static XML user, conf/clickhouse-users.d/ops-admin.xml,
# password from CH_OPS_PASSWORD, access_management=1). SQL-managed users:
#   grafana_ro  readonly SELECT on llm_gateway.* + growth-panel system tables
#               (NO request_bodies grant - dashboards/Explore cannot read bodies)
#   vector_rw   INSERT request_log + request_bodies
#   apisix_rw   INSERT usage_log
#   migrator    DDL/DML on llm_gateway.*
# `default` (password via CLICKHOUSE_PASSWORD, no access management) is
# locked to in-container localhost by the final ALTER.
set -euo pipefail

fail() { echo "[provision] ERROR: $*" >&2; exit 1; }

for v in CH_OPS_PASSWORD CH_GRAFANA_RO_PASSWORD CH_VECTOR_PASSWORD \
         CH_APISIX_PASSWORD CH_MIGRATOR_PASSWORD; do
    [ -n "${!v:-}" ] || fail "required env $v not set"
done

# Host-forwarded connections (rootless port publishing) arrive from the
# gw-ch gateway address; in-stack clients from the gw-ch subnet. The
# 10.99.60.x entries mirror this for the gw-test fixture stack.
STACK_HOSTS="'10.99.10.0/24', '10.99.60.0/24', '10.99.110.0/24'"

chq() {
    clickhouse-client --user ops_admin --password "$CH_OPS_PASSWORD" -q "$1"
}

chq "CREATE USER IF NOT EXISTS grafana_ro IDENTIFIED BY '$CH_GRAFANA_RO_PASSWORD'"
chq "ALTER USER grafana_ro IDENTIFIED BY '$CH_GRAFANA_RO_PASSWORD'"
chq "ALTER USER grafana_ro SETTINGS readonly = 1, allow_ddl = 0, max_execution_time CHANGEABLE_IN_READONLY"
chq "ALTER USER grafana_ro HOST IP $STACK_HOSTS"
chq "GRANT SELECT ON llm_gateway.* TO grafana_ro"
# The db-wide grant above covers request_bodies; strip it explicitly so
# dashboards/Explore can never read conversation bodies (FR-3.1).
chq "REVOKE SELECT ON llm_gateway.request_bodies FROM grafana_ro"
chq "GRANT SELECT ON system.parts TO grafana_ro"
chq "GRANT SELECT ON system.disks TO grafana_ro"
chq "GRANT SELECT ON system.tables TO grafana_ro"

chq "CREATE USER IF NOT EXISTS vector_rw IDENTIFIED BY '$CH_VECTOR_PASSWORD'"
chq "ALTER USER vector_rw IDENTIFIED BY '$CH_VECTOR_PASSWORD'"
chq "ALTER USER vector_rw HOST IP $STACK_HOSTS"
chq "GRANT INSERT ON llm_gateway.request_log TO vector_rw"
chq "GRANT INSERT ON llm_gateway.request_bodies TO vector_rw"

chq "CREATE USER IF NOT EXISTS apisix_rw IDENTIFIED BY '$CH_APISIX_PASSWORD'"
chq "ALTER USER apisix_rw IDENTIFIED BY '$CH_APISIX_PASSWORD'"
chq "ALTER USER apisix_rw HOST IP $STACK_HOSTS"
chq "GRANT INSERT ON llm_gateway.usage_log TO apisix_rw"
# WaitForAsyncInsert reads back the insert result, which requires SELECT on
# the written columns. usage_log is metadata only (no bodies), so this keeps
# the conversation-isolation invariant intact.
chq "GRANT SELECT ON llm_gateway.usage_log TO apisix_rw"

chq "CREATE USER IF NOT EXISTS migrator IDENTIFIED BY '$CH_MIGRATOR_PASSWORD'"
chq "ALTER USER migrator IDENTIFIED BY '$CH_MIGRATOR_PASSWORD'"
chq "ALTER USER migrator HOST IP $STACK_HOSTS"
chq "GRANT ALL ON llm_gateway.* TO migrator"

# `default` is locked to in-container localhost by the users.d override
# conf/clickhouse-users.d/default-local.xml (users.xml users cannot be
# ALTERed at runtime: ACCESS_STORAGE_READONLY).

echo "[provision] users + grants applied (grafana_ro, vector_rw, apisix_rw, migrator; ops_admin + default via XML)"
