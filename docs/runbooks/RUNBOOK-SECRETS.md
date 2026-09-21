# RUNBOOK-SECRETS: Credential Inventory and Rotation

**Date:** 2026-09-20
**Status:** Active
**Type:** Runbook

---

## Purpose

Inventory, generation, and rotation of every secret the gateway stack
consumes, plus the nightly ClickHouse backup job. All secrets live in the
gitignored repo-root `.env` (`chmod 600`); `.env.example` carries example
values only.

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
4. Verify: `make gw-verify`, dashboards render, live traffic writes
   `request_log`/`usage_log` (`curl -u "$CH_OPS_USER:$CH_OPS_PASSWORD" -s
   'http://127.0.0.1:8123/' --data 'SELECT count() FROM llm_gateway.request_log'
   --database llm_gateway`).
5. Provider-side rotations (`OPENCODE_API_KEY`): rotate at the provider
   first, update `.env`, then restart apisix.
6. etcd credential rotation: run `make etcd-auth-init` (re-binds
   `ETCD_GW_USER`), restart apisix.

## ClickHouse backups

Nightly (systemd timer `gateway-ch-backup.timer`, unit in
[`res/systemd/`](../../res/systemd/)): `BACKUP DATABASE llm_gateway TO
File('/backups/<date>')` into the staging directory, then synced to
`/mnt/ws-backup/workspace-gateway/` via the existing root write path. If
ws-backup is unwritable the backup stays in staging and the job logs a
warning (always logged, REQ-SECURITY-HARDENING NFR-1.4).

Restore drill (quarterly, into a scratch volume):

```bash
podman run --rm -v scratch-volume:/var/lib/clickhouse ... clickhouse-server
# inside: RESTORE DATABASE llm_gateway FROM File('/backups/<date>')
```

## Verification

- `gitleaks` clean on the repo (CI)  -  `.env` gitignored; `.gitleaksignore`
  fingerprints match current `.env` lines only.
- `stat -c %a .env` → `600`.
- After rotation: no auth errors in `make gw-logs SVC=vector` /
  `SVC=apisix` / `SVC=grafana` for 15 minutes of live traffic.
