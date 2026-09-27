# RUNBOOK-DEV-PROD-SEPARATION: Isolate the Dev and Prod Stacks

**Date:** 2026-09-27
**Status:** Completed
**Type:** Runbook

---

## Purpose

Separate the dev and prod gateway stacks while the dev stack keeps running and
its ClickHouse volume stays in place. Prod is not required and is left
untouched.

Separated means three things:

1. **Secrets** - dev reads `.env`, prod reads `.env.prod`; neither file is read
   by the other stack.
2. **Artifact** - prod runs config baked into its image (`Dockerfile.apisix`),
   so a repo edit cannot change prod without a rebuild.
3. **Namespace** - the dev compose project is renamed from the generic
   `docker` to `workspace-gateway-dev`, so no unrelated stack that runs from a
   directory named `docker` can collide with the gateway.

The volume and network runtime names are kept as-is (`docker_*`) so no data is
copied and the WORKSPACE-CI wiki nginx keeps its `docker_gw-edge` attachment.
Only the compose project changes.

## 1. Compose project rename

- [x] `res/docker/docker-compose.yml`: `name: workspace-gateway-dev`.
- [x] Explicit `container_name` for the three unnamed services: `gw-apisix`,
      `gw-clickhouse`, `gw-vector`.
- [x] Every top-level volume given an explicit `name:` equal to its runtime
      name, so the existing data is reused: `docker_clickhouse-data`,
      `docker_prometheus-data`, `docker_grafana-data`, `docker_openbao-data`,
      `docker_etcd-data`.
- [x] Every network given an explicit `name:` equal to its runtime name:
      `docker_gw-ch`, `docker_gw-etcd`, `docker_gw-secrets`,
      `docker_gw-metrics`, `docker_gw-ingest`, `docker_gw-edge` (marked
      `external: true` so compose can never remove it from the wiki nginx).
      `dataops` stays `external: true, name: dataops_default`.

## 2. Project-name consumers

- [x] `.env` and `.env.example`: `COMPOSE_PROJECT_NAME=workspace-gateway-dev`.
- [x] `res/scripts/gateway-compose.sh`: passes `-p` and uses the project in
      both `io.podman.compose.project` filters.
- [x] `res/scripts/gateway-compose-up.sh`: passes `-p`.
- [x] `res/scripts/drain-apisix.sh`: default container `gw-apisix`.
- [x] `Makefile`: `gw-shell` execs `gw-apisix`.
- [x] `res/ansible/dev.yml` (`-p` + container vars), `res/ansible/compose.yml`
      (status filter), `res/ansible/services.yml` (container list).
- [x] `res/scripts/crunch-usefulness.sh`, `res/scripts/recalc-costs.sh`:
      apisix lookup filter.
- [x] `tests/run_all.sh`, `tests/integration/run.sh`,
      `tests/integration/test_recalc_costs_run.sh`,
      `tests/e2e/test_security_lockdown.sh`.

## 3. Restart the dev service (final step)

- [x] Stopped the systemd unit; removed the orphaned `docker_*` containers with
      `podman rm -f --depend` so they released their static network IPs and
      host ports. Volumes and networks were left in place.
- [x] Started through the sanctioned target: `make gw-start`. It reused the
      named volumes and networks and brought the stack up as `gw-*`.

## Verification

- [x] All seven containers run under `workspace-gateway-dev`: `gw-apisix`,
      `gw-clickhouse`, `gw-vector`, `gw-openbao`, `gw-etcd`, `gw-prometheus`,
      `gw-grafana`. Unit `gateway-compose.service` active and enabled.
- [x] `gw-clickhouse` is mounted on the existing `docker_clickhouse-data`
      (request_log / usage_log rows intact and still growing with live traffic);
      no `workspace-gateway-dev_*` volume was created.
- [x] `make gw-start` reached "Stack is ready"; gateway root answers on :9080.
- [x] Public Grafana auth intact:
      `https://workspaceguardrails.com/grafana/api/user` returns 200.
- [x] `tests/config/run.sh` 25/25, `tests/scripts/run.sh` 3/3,
      `tests/e2e/test_security_lockdown.sh` 25/25.

## Result

- Dev and prod now differ in project name, secrets file, and config source,
  with no shared credential file and no shared config bind mount.
- No `podman volume rename` exists; keeping the runtime names through compose
  `name:` is the supported way to move the project without an export/import of
  the 37 GB ClickHouse volume. Volume names still read `docker_*`.
- Prod was not restarted during the rename. `make gw-verify` passes: the
  health report is all UP and the sanity request returns 200.

## W3 - prod observability (same Grafana)

The dev Grafana serves both stacks.
`conf/grafana/provisioning/datasources/datasources.yml` defines a second
read-only ClickHouse datasource, `clickhouse-prod` (`grafana_ro`, no
`request_bodies` grant), reached over the shared `gw-metrics-prod` bridge so
prod ClickHouse keeps its loopback-only host publish. The dashboards keep
their default `clickhouse` (dev) datasource; the prod datasource is available
for manual selection.

- [x] `clickhouse-prod` provisioned (native, `gw-prod-clickhouse:9000`).
- [x] `gw-metrics-prod` (external, 10.99.150.0/24) declared in both composes
      and attached to dev Grafana and prod ClickHouse; created once with
      `podman network create --subnet 10.99.150.0/24 gw-metrics-prod`.
- [x] `grafana_ro` HOST IP list now includes 10.99.150.0/24.
- [x] Dev Grafana healthy; dashboards unchanged. The prod datasource reports
      unreachable only while prod is off.
- [ ] Deferred with prod: Prometheus scrape target for `gw-prod-apisix:9100`.

## Prod teardown (2026-09-27)

Prod is stopped and uninstalled:

- [x] `gw-prod-pod.service` stopped, disabled, and its unit file removed
      (`systemctl --user stop`/`disable`, `rm`, `daemon-reload`).
- [x] Pod `pod_workspace-gateway-prod` and its five `gw-prod-*` containers
      removed; ports 9081/9444/8124 closed.
- [x] Prod data volumes kept:
      `workspace-gateway-prod_prod-clickhouse-data`,
      `workspace-gateway-prod_prod-openbao-data`,
      `workspace-gateway-prod_prod-etcd-data`.
- Reinstall: `make gw-prod-build` then `make gw-prod-start` (prod compose is
  the source of truth; the removed pod unit was not repo-managed).
