# Gateway Automation Audit

**Date:** 2026-08-05
**Scope:** WORKSPACE-GATEWAY lifecycle, deployment, readiness, route control plane,
testing, and operational documentation
**Status:** Remediation implemented; final external/live validation pending

## Current Remediation State

Implemented and verified:

- Production APISIX plugin imports use the namespaced module layout, including
  `redact`; startup checks the loaded plugin registry before route mutation.
- Normal restart, update, reconcile, and service restart have separate Make
  semantics, with systemd as the lifecycle owner.
- Migration is profile-gated and runs from the Ansible readiness sequence after
  ClickHouse initialization and health checks.
- Route reconciliation deletes stale managed routes and verifies the exact
  managed route set after seeding.
- Internal service ports bind to loopback, and administrative credentials are
  passed through a temporary mode-0600 file rather than a process argument.
- Compose and test Compose include healthcheck/readiness definitions, and the
  test stack is project-scoped.
- Provider login has bounded HTTP behavior and an explicit headless clipboard
  mode.

Verification completed twice consecutively with `tests/run_all.sh`: all seven
stages passed on both runs. Live API tests can be forced with
`bash tests/e2e/run.sh --live`; the current upstream account returns
`CreditsError` / HTTP 401 for paid Zen models, so those provider-dependent
checks cannot pass until the account has balance.

Remaining follow-up:

- Add failure-injection tests for build rollback, failed plugin readiness,
  failed migration, and OpenBao signal forwarding.
- Replace the duplicated test Compose file with generated or mechanically
  checked parity against production Compose.
- Complete topology/runbook regeneration and document the loopback-only host
  bindings.
- Validate OpenAI Responses telemetry with real provider traffic.
- Address CI/runtime-specific descriptor and health-monitoring behavior where
  the rootless Podman environment does not schedule healthchecks automatically.

## Executive Summary

The gateway automation does not have one coherent lifecycle contract. Make,
Ansible, a long-running systemd unit, podman-compose, and per-container restart
policies all participate in starting and stopping the same stack. The result is
that commands named `restart` can build images, destroy containers, rerun
migrations, reseed routes, and trigger provider synchronization, while systemd
can independently tear down and restart the entire stack.

The most urgent production defect is APISIX plugin registration. The live Admin
API reports `redact` absent, and APISIX logs show:

```text
failed to get schema for plugin: redact
skipping check schema for disabled or unknown plugin [redact]
```

The direct cause is `plugins/custom/redact_walk.lua` importing
`redact_lib` instead of `apisix.plugins.redact_lib`. The Lua unit runner masks
this defect by adding `plugins/custom` directly to its module path. The prior
gateway verification also accepted HTTP `401` as success and did not inspect
the APISIX plugin registry.

The restart failure also exposed a real dependency race: Compose starts the
one-shot migration container before ClickHouse is ready. The captured journal
contains `connect: connection refused` from `migrate`, and Vector reports a
failed ClickHouse sink health check during the same startup window.

## Evidence Rules

This audit distinguishes:

- **Observed:** confirmed by source inspection or bounded runtime commands.
- **Documented:** confirmed by authoritative upstream documentation.
- **Inferred:** strongly suggested by structure, but requiring a dedicated
  runtime test.

No existing code or worktree changes were reverted during the audit.

## Authoritative References

- [Podman restart](https://docs.podman.io/en/latest/markdown/podman-restart.1.html):
  restarts existing containers; it does not recreate them.
- [Podman run restart policies](https://docs.podman.io/en/v5.8.0/markdown/podman-run.1.html):
  when containers run under systemd, use systemd restart policy rather than
  combining both mechanisms.
- [Podman Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html):
  recommended declarative systemd integration and health-aware startup.
- [Compose restart](https://docs.docker.com/reference/cli/docker/compose/restart/):
  restarts existing service containers and does not apply Compose changes.
- [Compose up](https://docs.docker.com/reference/cli/docker/compose/up/):
  creates/reconciles containers and may recreate them when image or
  configuration changes.
- [Compose service specification](https://compose-spec.github.io/compose-spec/05-services.html):
  `service_healthy` dependencies require health checks.
- [APISIX Admin API](https://apisix.apache.org/docs/apisix/admin-api/):
  `/apisix/admin/plugins/list` exposes the loaded plugin registry.
- [APISIX plugin development](https://apisix.apache.org/docs/apisix/next/plugin-develop/):
  custom modules are loaded as `apisix.plugins.<plugin_name>`.
- [systemd service](https://freedesktop.org/software/systemd/man/devel/systemd.service.html):
  `Type=simple` reports started before application readiness and
  `TimeoutStopSec` bounds `ExecStop`.
- [ClickHouse HTTP interface](https://clickhouse.com/docs/concepts/features/interfaces/http):
  `/ping` is the availability endpoint.

## Lifecycle Inventory

### Make

- `gw-build` builds images.
- `gw-start` deploys/enables the systemd unit, starts the stack, waits for
  dependencies, initializes ClickHouse, migrates, seeds routes, and syncs
  providers.
- `gw-stop` stops the systemd unit.
- `gw-restart` drains APISIX, builds images, restarts the systemd unit, then
  repeats the full startup/setup sequence.
- `gw-restart-service` directly invokes Compose outside systemd and recreates
  one service.
- `gw-restart-grafana` recreates Grafana and independently reloads provisioning.
- `gw-clean` stops and removes volumes while suppressing failures.
- `gw-verify` reports endpoint health and sends a sanity request, but currently
  treats any HTTP response as successful.

### Ansible and systemd

`res/ansible/compose.yml` installs a user unit whose `ExecStartPre` runs
`compose down`, removes `docker_default`, and globally removes all stopped,
dead, and created Podman containers. Its `ExecStart` invokes
`res/scripts/gateway-compose-up.sh`, which loads the project `.env`, acquires a
process lock, starts ClickHouse, Vector, OpenBao, Prometheus, Grafana, and etcd
one at a time, then keeps APISIX attached in the foreground. The unit also sets
`Restart=always`.

`res/ansible/dev.yml` renders the route source, creates the external network,
waits on several HTTP endpoints, seeds routes, initializes ClickHouse, runs
migrations, waits on observability services, and triggers provider sync.

### Compose

Production Compose defines APISIX, ClickHouse, a one-shot migration service,
Vector, OpenBao, Prometheus, Grafana, and etcd. Long-running services use
`restart: unless-stopped`, while the migration service starts automatically
when the whole Compose project is brought up.

## Findings

### Critical: Broken APISIX plugin registration

**Observed.** `GET /apisix/admin/plugins/list` does not contain `redact`.
Eleven live routes reference `redact`. APISIX logs show schema lookup failure.

**Cause.** `redact_walk.lua` uses a bare import. The production module path is
the APISIX namespace, while the unit tests use `-I /plugins/custom` and accept
the bare import.

**Remediation.** Use namespaced imports, test imports through the production
layout, and make startup fail before route seeding if required plugins are
absent.

### Critical: False-positive verification

`res/ansible/dev.yml` only fails the sanity request when `curl` itself fails.
HTTP `401`, `404`, and `500` all produce a successful curl process. The recent
verification reported success while the sanity request returned `401` and the
`redact` plugin was absent.

**Remediation.** Define explicit acceptable statuses and add checks for plugin
registry, route count, route/plugin compatibility, provider sync response,
ClickHouse schema, Vector readiness, and migration version.

### Critical: Migration starts before ClickHouse readiness

`migrate` is part of ordinary Compose startup and only has short-form
`depends_on: clickhouse`. Ansible later waits for ClickHouse and invokes
migration a second time. The startup journal confirms the first migration
attempt failed against port 9000 before ClickHouse was accepting connections.

**Remediation.** Remove migration from default long-running startup and make
Ansible the sole owner, or add a real ClickHouse health check and
`service_healthy` dependency. Do not retain two migration owners.

### High: Competing lifecycle supervisors

The stack is simultaneously controlled by systemd, podman-compose, and
container restart policies. Direct service recreation bypasses systemd while
the systemd unit remains attached to the project. Podman documentation warns
against combining container restart policy with systemd restart ownership.

**Remediation.** Choose one owner. The target architecture uses systemd as the
boot/crash supervisor and Compose as the declarative deployment tool. Normal
restart uses existing-container restart semantics. Update/redeploy is a
separate explicit operation.

### High: Destructive global cleanup

The systemd unit deletes all stopped/dead/created Podman containers and removes
the generic `docker_default` network. These operations are not scoped to this
Compose project and can damage unrelated workloads. Cleanup failures are
ignored.

**Remediation.** Remove global cleanup. Use Compose project labels and explicit
resource names. Make teardown failures visible and fatal.

### High: Network creation occurs after stack start

`dataops_default` is external and required by Compose, but Ansible starts the
systemd unit before creating it. Clean-host startup therefore depends on the
systemd restart loop.

**Remediation.** Create and validate external networks before starting Compose.

### High: Drain timeout contradicts systemd timeout

APISIX is configured for a 300-second graceful stop, while systemd has
`TimeoutStopSec=120`. Normal `gw-stop` does not call the drain helper.

**Remediation.** Set one bounded drain contract and use it consistently in
  Compose, systemd, and Make. Ensure stop status reflects timeout/failure.

### High: Build failure can leave APISIX down

`gw-restart` drains APISIX before building. A build error exits before the
  systemd restart step.

**Remediation.** Build and validate first; only drain when the deployment step
  is ready, or provide a rollback/start recovery trap.

### High: Readiness is incomplete

There are no Compose health checks. Vector has no readiness probe. APISIX HTTP
readiness does not validate plugin registration. Migrations and provider sync
are not part of a strict readiness contract.

**Remediation.** Add service health checks and explicit ordered readiness gates.
Use bounded retries and fail closed.

### High: Route seeding is not authoritative

`seed-routes.sh` only PUTs routes found in the source file. Removed routes are
not deleted, routes without IDs are skipped, and individual requests have no
retry. Traditional APISIX mode stores routes in etcd, so the source file must
be reconciled rather than merely appended/upserted.

**Remediation.** Validate all IDs, list managed routes, delete stale managed
routes, PUT desired routes, and verify the resulting set exactly.

### High: Secrets are exposed to process inspection

Ansible passes the admin key as a command-line argument without `no_log`.
Several internal services are broadly host-published.

**Remediation.** Use environment/file-based secret input with `no_log`, bind
administrative/data ports to loopback or internal networks, and document the
remaining intentional exposures.

### High: Test environment masks production defects

The Lua runner adds the source directory directly to its module path. The test
Compose file has drifted from production. Integration detection matches any
container containing `apisix`, and teardown errors are swallowed. The wrapper
test is not included in the script test runner.

**Remediation.** Test the production module layout, derive test Compose from
production, scope detection by project labels, fail teardown, and execute all
tests.

### Medium: Lifecycle names and documentation are misleading

`gw-start` performs deployment and schema setup. `gw-restart` builds images and
reconciles application state. There is no `redeploy` or `update` target. The
runbook instructs direct Compose operation while README says systemd owns the
stack. Comments incorrectly describe standalone APISIX mode.

**Remediation.** Define and document separate commands for start, stop,
restart, deploy, update, reconcile, and clean. Remove contradictory procedures.

### Medium: Route and status observability are incomplete

`gw-status` filters only `gw-*`, omitting APISIX, ClickHouse, and Vector.
`gw-logs` follows every service indefinitely. Runtime topology contains stale
ports, counts, and versions.

**Remediation.** Use project labels for status, add bounded service log
commands, and regenerate topology documentation from the authoritative Compose
definition.

### Medium: OpenBao signal handling is incomplete

The entrypoint backgrounds the server and waits without an explicit signal
forwarding trap. Graceful stop behavior is therefore not established by test.

**Remediation.** Add signal forwarding and a bounded shutdown test.

## Remediation Work Breakdown

1. Fix all production namespace imports and add a production-layout loader test.
2. Add APISIX plugin registry and route-set gates before route reconciliation.
3. Correct `gw-verify` HTTP status handling and make it validate real readiness.
4. Move external network creation before Compose start.
5. Remove automatic migration startup and retain one migration owner.
6. Add ClickHouse, Vector, APISIX, OpenBao, etcd, Prometheus, and Grafana health
   checks with ordered dependencies.
7. Define separate Make semantics for start, stop, restart, deploy, update,
   reconcile, and clean.
8. Remove global systemd cleanup and duplicate restart policies.
9. Align drain and stop timeouts and add failure recovery around restart.
10. Make route reconciliation exact and idempotent, including stale deletion.
11. Harden secret transport, host bindings, timeouts, retries, and failure
    propagation.
12. Unify production and test Compose definitions and add lifecycle tests.
13. Update README, runbooks, topology, project metadata, and test plans.
14. Run static, unit, integration, lifecycle, and two-consecutive-restart
    verification before declaring the remediation complete.

## Exit Criteria

The remediation is complete only when all of the following hold:

- A clean production-layout APISIX load registers every configured custom
  plugin, including `redact`.
- A normal restart preserves container IDs and does not build or recreate.
- An update explicitly rebuilds/reconciles changed services.
- A fresh deployment creates networks before services.
- Migration runs exactly once after ClickHouse readiness.
- Route reconciliation leaves etcd with exactly the managed desired route set.
- Verification fails on plugin, route, migration, telemetry, or HTTP errors.
- No lifecycle command can delete unrelated containers or networks.
- Test Compose and production Compose have verified parity.
- Full verification passes twice consecutively without one-off recovery steps.
