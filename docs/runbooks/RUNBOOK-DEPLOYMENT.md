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
- Repo-root `.env` file with `ADMIN_KEY`, `OPENCODE_API_KEY`, `OPENBAO_TOKEN`
  (consumed via `env_file` in compose).

## Procedures

### 1. Bring the stack up

1. From the repo root:
   ```bash
   podman-compose -f res/docker/docker-compose.yml up -d --build
   ```
2. Services started: `apisix` (ports 9080/9443/9180/9100), `clickhouse`
   (8123/9000), `migrate` (one-shot golang-migrate runner), `vector`
   (18080->8080), `openbao` (8201->8200), `prometheus` (9092->9090),
   `grafana` (127.0.0.1:3030->3000), `etcd` (2379).
3. The `migrate` service runs `migrate up` against
   `clickhouse://clickhouse:9000/llm_gateway` using `/migrations` from
   `conf/migrations/` and exits (`restart: "no"`). Re-run manually:
   ```bash
   podman-compose -f res/docker/docker-compose.yml run --rm migrate up
   podman-compose -f res/docker/docker-compose.yml run --rm migrate version
   ```

### 2. Tear the stack down

```bash
podman-compose -f res/docker/docker-compose.yml down
```

Add `-v` to also drop volumes (`clickhouse-data`, `prometheus-data`,
`grafana-data`, `openbao-data`, `etcd-data`). Dropping `openbao-data` destroys
all issued gateway keys.

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
podman-compose -f res/docker/docker-compose.yml restart apisix
```

### 4. Config files touched (per service)

| Service | Mounted config |
|---------|----------------|
| apisix | `conf/apisix.yaml`, `conf/config.yaml`, `conf/providers/`, `conf/redact-patterns.json`, `plugins/custom/*.lua` |
| clickhouse | `conf/clickhouse-init.sql` (initdb), `conf/migrations/` (via migrate) |
| vector | `conf/vector.toml` |
| openbao | `conf/openbao.hcl` |
| prometheus | `conf/prometheus.yml` |
| grafana | `conf/grafana/provisioning/`, `conf/grafana/dashboards/` |

Deployment mode is etcd/traditional (`conf/config.yaml`: `role: traditional`,
`config_provider: etcd`). `conf/apisix.yaml` is mounted and used as the seed
source; route changes require an apisix restart (or re-sync), they are not
hot-polled.

### 5. Health checks

```bash
# APISIX status + Prometheus metrics
curl -s http://localhost:9080/apisix/status
curl -s http://localhost:9100/apisix/prometheus/metrics | head

# ClickHouse
curl -s http://localhost:8123/ping

# Vector ingest endpoint (listening check)
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:18080/

# OpenBao
curl -s http://localhost:8201/v1/sys/health

# Grafana / Prometheus UIs
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3030/api/health
curl -s http://localhost:9092/-/ready
```

### 6. Logs

```bash
podman-compose -f res/docker/docker-compose.yml logs -f apisix
podman-compose -f res/docker/docker-compose.yml logs -f vector
podman-compose -f res/docker/docker-compose.yml logs migrate
```

### 7. ClickHouse access

Database `llm_gateway` (tables `request_log`, `usage_log`, `billing_ledger`,
`billing_discrepancies`; migrations 000001..000005 in `conf/migrations/`).

```bash
# HTTP interface
curl -s 'http://localhost:8123/?database=llm_gateway' --data 'SHOW TABLES'

# Native client inside the container
podman exec -it $(podman ps --format '{{.Names}}' | grep clickhouse) \
  clickhouse-client --database llm_gateway
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
curl -s 'http://localhost:8123/?database=llm_gateway' \
  --data 'SELECT * FROM billing_discrepancies ORDER BY flagged_at DESC LIMIT 20 FORMAT TSVWithNames'
```

## Verification

After bring-up, all of the following must hold:

1. `podman ps` shows apisix, clickhouse, vector, openbao, prometheus, grafana,
   etcd running.
2. `curl http://localhost:9080/apisix/status` returns a JSON status payload.
3. `curl http://localhost:8123/ping` returns `Ok.`.
4. `migrate version` reports the highest applied migration.
5. `curl http://localhost:9092/-/ready` returns `Prometheus Server is Ready.`

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| apisix exits immediately | Missing/invalid `.env` (`ADMIN_KEY`, `OPENCODE_API_KEY`, `OPENBAO_TOKEN`) | Check `logs apisix`; fix `.env` |
| apisix up but routes 404 | etcd not seeded / stale | `restart apisix`; verify etcd container healthy |
| `network dataops_default not found` | External network missing | `podman network create dataops_default` |
| ClickHouse tables missing | init.sql only runs on empty volume; migrations not applied | `run --rm migrate up`; check `logs migrate` |
| Vector ingest connection refused | Vector not up or port mismatch | Endpoint is host port 18080; check `logs vector` |
| OpenBao sealed / token rejected | Volume reset or wrong `OPENBAO_TOKEN` | See [RUNBOOK-KEYS](RUNBOOK-KEYS.md); check `logs openbao` |
| Grafana login fails in dev | Auth-proxy enabled by default | Set `GF_AUTH_ANONYMOUS_ENABLED=true` in `.env` for dev |
