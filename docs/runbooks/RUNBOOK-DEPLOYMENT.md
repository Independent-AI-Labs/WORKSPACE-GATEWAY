# RUNBOOK-DEPLOYMENT: Gateway Stack Operations

**Date:** 2026-07-17
**Status:** Active
**Type:** Runbook

---

## Purpose

Operational procedures for bringing the WORKSPACE-GATEWAY compose stack up and
down, building the custom APISIX image, verifying health, reading logs, querying
ClickHouse, and running the reconciler. Runtime topology and service inventory:
[RUNTIME-TOPOLOGY](../architecture/RUNTIME-TOPOLOGY.md).

## Prerequisites

- Podman + podman-compose installed.
- The external `dataops_default` network exists:
  ```bash
  podman network create dataops_default 2>/dev/null || true
  ```
- Repo-root `.env` file (`0600`) with `ADMIN_KEY`, `OPENCODE_API_KEY`,
  `OPENBAO_TOKEN`, `GRAFANA_ADMIN_PASSWORD`, the ClickHouse credential set
  (`CLICKHOUSE_PASSWORD`, `CH_GRAFANA_RO_PASSWORD`, `CH_VECTOR_PASSWORD`,
  `CH_APISIX_PASSWORD`, `CH_MIGRATOR_PASSWORD`, `CH_OPS_PASSWORD`), and the
  etcd credential set (`ETCD_ROOT_PASSWORD`, `ETCD_GW_USER`,
  `ETCD_GW_PASSWORD`)  -  see [RUNBOOK-SECRETS](RUNBOOK-SECRETS.md)
  (consumed via `env_file` in compose).

## Procedures

### 1. Bring the stack up

1. From the repo root, use the systemd-owned lifecycle target:
    ```bash
    make gw-start
   ```
2. Services started: `apisix` (public 9080/9443), `clickhouse` (loopback
   8123, authenticated), `migrate` (one-shot golang-migrate runner,
   authenticates as `migrator`), `vector`, `openbao`, `prometheus`,
   `grafana` (loopback 3030, edge-proxy auth), and `etcd` (RBAC)  -  the
   latter five have **no published host ports**; reach them via
   `podman exec` or compose DNS (REQ-SECURITY-HARDENING FR-6).
3. The `migrate` service is profile-gated and is run once by Ansible after
   ClickHouse readiness. Re-run manually through the repository wrapper:
     ```bash
     make ch-provision        # (re)provision ClickHouse users + grants
     make etcd-auth-init      # one-shot: enable etcd RBAC (first deploy)
     make ch-migrate
     make ch-migrate-status
     ```

### 2. Tear the stack down

```bash
make gw-stop
```

Gateway lifecycle operations preserve all persistent volumes.

### 3. Build the APISIX image only

[`res/docker/Dockerfile.apisix`](../../res/docker/Dockerfile.apisix) is based on
`apache/apisix:3.17.0-debian` and COPYs the 15 custom plugin/lib files from
`plugins/custom/` flat into `/usr/local/apisix/apisix/plugins/`, plus
`conf/config.yaml`, `conf/redact-patterns.json`, and `conf/providers/`.

```bash
podman build -f res/docker/Dockerfile.apisix -t gateway-apisix .
```

For live development the compose file already volume-mounts every plugin file
`:ro` over the image copies, so Lua edits only need an apisix restart:

```bash
make gw-restart-service SVC=apisix
```

### 4. Config files touched (per service)

| Service | Mounted config |
|---------|----------------|
| apisix | `conf/apisix.yaml`, `conf/config.yaml`, `conf/providers/`, `conf/redact-patterns.json`, `plugins/custom/*.lua` |
| clickhouse | `conf/sql/clickhouse-init.sql` (initdb), `conf/sql/migrations/` (via migrate) |
| vector | `conf/vector.toml` |
| openbao | `conf/openbao.hcl` |
| prometheus | `conf/prometheus.yml` |
| grafana | `conf/grafana/provisioning/`, `conf/grafana/dashboards/` |

Deployment mode is etcd/traditional (`conf/config.yaml`: `role: traditional`,
`config_provider: etcd`). `conf/apisix.yaml` is reconciled into etcd by the
startup workflow; route changes do not require an APISIX restart, but do require
`make gw-reconcile` once that target is available.

### 5. Health checks

```bash
# APISIX status (public data plane)
curl -s http://localhost:9080/apisix/status

# ClickHouse (ping needs no auth)
curl -s http://localhost:8123/ping

# No-published-port services: exec from inside the stack
podman exec gw-prometheus wget -qO- http://127.0.0.1:9090/-/ready
podman exec gw-openbao     curl -fsS http://127.0.0.1:8200/v1/sys/health
podman exec gw-vector      curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/
podman exec gw-etcd        etcdctl --user "$ETCD_GW_USER:$ETCD_GW_PASSWORD" endpoint health
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3030/api/health   # Grafana (loopback)
```

### 6. Logs

```bash
   make gw-logs SVC=apisix
   make gw-logs SVC=vector
   make gw-logs SVC=migrate
```

### 7. ClickHouse access

Database `llm_gateway` (tables `request_log`, `request_bodies`, `usage_log`,
`billing_ledger`, `billing_discrepancies`; migrations in `conf/sql/migrations/`).
All access is authenticated (RUNBOOK-SECRETS); conversation bodies live in
`request_bodies`, readable only by `ops_admin`.

```bash
# HTTP interface (ops_admin basic auth)
curl -u "$CH_OPS_USER:$CH_OPS_PASSWORD" -s \
  'http://localhost:8123/?database=llm_gateway' --data 'SHOW TABLES'

# Native client inside the container (default user, localhost-only)
podman exec -it gw-clickhouse clickhouse-client --password "$CLICKHOUSE_PASSWORD" \
  --database llm_gateway
```

### 8. Reconciler ops

[`res/scripts/reconciler.sh`](../../res/scripts/reconciler.sh) cross-checks the
ClickHouse ledger for yesterday against upstream provider usage and inserts
divergences beyond tolerance into `billing_discrepancies`. Run daily via cron
at 02:00, or manually:

```bash
bash res/scripts/reconciler.sh
```

Inspect flagged rows:

```bash
curl -u "$CH_OPS_USER:$CH_OPS_PASSWORD" -s 'http://localhost:8123/?database=llm_gateway' \
  --data 'SELECT * FROM billing_discrepancies ORDER BY flagged_at DESC LIMIT 20 FORMAT TSVWithNames'
```

## Verification

After bring-up, all of the following must hold:

1. `podman ps` shows apisix, clickhouse, vector, openbao, prometheus, grafana,
   etcd running.
2. `curl http://localhost:9080/apisix/status` returns a JSON status payload.
3. `curl http://localhost:8123/ping` returns `Ok.`.
4. `migrate version` reports the highest applied migration.
5. `curl http://127.0.0.1:3030/api/health` returns 200.
6. Security matrix (REQ-SECURITY-HARDENING V7) passes: unauthenticated
   ClickHouse query → 401; `grafana_ro` DDL/INSERT → denied;
   `request_bodies` invisible to `grafana_ro`; `ss -tlnp` shows only
   9080/9081/9443/9444 public plus loopback 8123/8124/3030.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| apisix exits immediately | Missing/invalid `.env` | Check `logs apisix`; fix `.env` per RUNBOOK-SECRETS |
| apisix up but routes 404 | etcd not seeded / stale | run the route reconciliation workflow; verify the APISIX plugin registry and etcd |
| `network dataops_default not found` | External network missing | `podman network create dataops_default` |
| ClickHouse tables missing | init.sql only runs on empty volume; migrations not applied | `run --rm migrate up`; check `logs migrate` |
| ClickHouse 401 from scripts | `CH_OPS_USER`/`CH_OPS_PASSWORD` not exported | Source `.env` in the shell / cron unit |
| Vector insert auth failures | `CH_VECTOR_PASSWORD` rotated but vector not restarted | `make gw-restart-service SVC=vector` |
| OpenBao sealed / token rejected | Volume reset or wrong `OPENBAO_TOKEN` | See [RUNBOOK-KEYS](RUNBOOK-KEYS.md); `podman exec gw-openbao` to inspect |
| Grafana datasource errors | `CH_GRAFANA_RO_PASSWORD` not set or user not provisioned | `make ch-provision`; restart grafana |
| Grafana login rejected everywhere | Edge proxy not in `GF_AUTH_PROXY_WHITELIST` or header stripped at edge | See [RUNBOOK-EDGE-PROXY](RUNBOOK-EDGE-PROXY.md) |
