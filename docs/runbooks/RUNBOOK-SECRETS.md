# RUNBOOK-SECRETS: Credential Inventory and Rotation

**Date:** 2026-09-20
**Status:** Active
**Type:** Runbook

---

## Purpose

Inventory, generation, and rotation of every secret the gateway stack
consumes, plus the nightly ClickHouse backup job.

Two independent secret files exist, one per stack, so neither can
re-provision the other:

| File | Stack | Template | Consumers |
|------|-------|----------|-----------|
| `.env` | dev (`docker-compose.yml`) | `.env.example` | dev containers, `make ch-provision`/`test`, ansible, dev systemd units |
| `.env.prod` | prod (`docker-compose.prod.yml`) | `.env.prod.example` | prod containers, `gateway-prod.sh` (build/start/verify) |

Both are gitignored and MUST be `chmod 600`. Templates carry example values
only. A dev edit to `.env` never reaches prod, and vice versa; rotate each
stack by editing its own file and restarting that stack's consumers.

## Inventory

| Variable | Consumed by | Notes |
|----------|-------------|-------|
| `ADMIN_KEY` | APISIX Admin API | MUST be a random 32-hex value  -  the public APISIX demo key is forbidden |
| `OPENCODE_API_KEY` | key-resolver upstream | Rotate at provider when exposed |
| `OPENBAO_TOKEN` | key-resolver / scripts | OpenBao service token |
| `GRAFANA_ADMIN_PASSWORD` | Grafana | Strong value; never `admin` |
| `GRAFANA_EDGE_CIDR` | `GF_AUTH_PROXY_WHITELIST` | gw-ch gateway + `127.0.0.1` |
| `CLICKHOUSE_PASSWORD` | CH `default` user | Strong; localhost-only user |
| `CH_GRAFANA_RO_PASSWORD` | Grafana datasource | readonly account |
| `CH_VECTOR_PASSWORD` | Vector sink | insert-only account |
| `CH_APISIX_PASSWORD` | sse-usage (`CH_APISIX_PASSWORD` env into apisix) | insert-only account |
| `CH_MIGRATOR_PASSWORD` | migrate DSN | DDL account |
| `CH_OPS_PASSWORD` | host scripts (`ops_admin`) | full account  -  guard like root |
| `ETCD_ROOT_PASSWORD` | etcd bootstrap | keep only for `make etcd-auth-init` |
| `ETCD_GW_USER` / `ETCD_GW_PASSWORD` | APISIX → etcd | non-root, `/apisix` prefix only |

## Generation

```bash
openssl rand -hex 16   # ADMIN_KEY-style
openssl rand -base64 24 # passwords
```

## Rotation procedure

1. Append new values to `.env` (keep old values until step 4 verifies).
2. Re-provision ClickHouse users (idempotent, updates passwords in place):
   ```bash
   make ch-provision
   ```
3. Restart consumers of each rotated credential:
   ```bash
   make gw-restart-service SVC=vector
   make gw-restart-service SVC=grafana
   make gw-restart-service SVC=apisix   # CH_APISIX_PASSWORD, etcd creds
   ```
   `GRAFANA_ADMIN_PASSWORD` is special: `GF_SECURITY_ADMIN_PASSWORD` is read
   only when Grafana first initializes its database. On an existing
   `grafana-data` volume a restart does NOT apply a rotated value, so set it
   in place after restarting (`PUT /api/admin/users/1/password` as the current
   admin, or `grafana-cli admin reset-admin-password`); wiping `grafana-data`
   re-seeds from `.env` but loses Grafana state. Integration tests read
   `GRAFANA_ADMIN_PASSWORD` from `.env` (never the `admin` default).
4. Verify: `make gw-verify`, dashboards render, live traffic writes
   `request_log`/`usage_log`:

   ```bash
   curl -u "$CH_OPS_USER:$CH_OPS_PASSWORD" -s 'http://127.0.0.1:8123/' \
     --data 'SELECT count() FROM llm_gateway.request_log' --database llm_gateway
   ```
5. Provider-side rotations (`OPENCODE_API_KEY`): rotate at the provider
   first, update `.env`, then restart apisix.
6. etcd credential rotation: run `make etcd-auth-init` (re-binds
   `ETCD_GW_USER`), restart apisix.

### Prod stack

Prod reads `.env.prod` only. Rotate it by editing `.env.prod`, then
`make gw-prod-redeploy` (guarded: stop + start + verify). This bounces the
prod data plane, so schedule it; `make gw-prod-stop` is refused without
`--confirm`. `make etcd-auth-init` re-binds the prod etcd user from
`.env.prod` when `gw-prod-etcd` is running. Prod ClickHouse users are
re-provisioned on `gw-prod-redeploy` start.

## ClickHouse backups

Nightly (systemd timer `gateway-ch-backup.timer`, unit in
[`res/ansible/templates/`](../../res/ansible/templates/)): the
`BACKUP DATABASE llm_gateway TO File('/backups/<date>')` statement into the
staging directory, then synced to
`/mnt/ws-backup/workspace-gateway/` via the existing root write path. If
ws-backup is unwritable the backup stays in staging and the job logs a
warning (always logged, REQ-SECURITY-HARDENING NFR-1.4).

Restore drill (quarterly, into a scratch volume):

```bash
podman run --rm -v scratch-volume:/var/lib/clickhouse ... clickhouse-server
# inside: RESTORE DATABASE llm_gateway FROM File('/backups/<date>')
```

## Verification

- `gitleaks` clean on the repo (CI)  -  `.env` is gitignored and the
  WORKSPACE-CI `ci_scan_secrets` wrapper allowlists every git-ignored path, so
  no `.env` content is scanned.
- `stat -c %a .env` → `600`.
- After rotation: no auth errors in `make gw-logs SVC=vector` /
  `SVC=apisix` / `SVC=grafana` for 15 minutes of live traffic.
