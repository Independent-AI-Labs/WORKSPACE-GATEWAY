# WORKSPACE-GATEWAY Destructive-Path Audit

**Date:** 2026-08-21
**Scope:** Every command in WORKSPACE-GATEWAY (working tree, `9f39202` plus
pending changes) that can delete containers, volumes, tables, databases,
users, or host state.
**Method:** Pattern scan (`rm -[a-zA-Z]*[rRf]`, `volume rm`, `down -v`,
`DROP TABLE`, `TRUNCATE`, `prune`) across the Makefile, `res/scripts/`,
`res/ansible/`, `res/docker/`, tests, and plugins, followed by manual review
of every hit in context.

## Inventory

### Bounded temporary cleanup (no persistent data)

| Location | Operation | Classification |
| --- | --- | --- |
| `res/scripts/opencode-provider-login.sh:93`, `backfill-reasoning-tokens.sh:110`, `gen-model-registry.sh:182-210` | `rm -rf/-f "$TMP..."` on self-created temp paths | Own temp artifacts |
| `Makefile:253-266` | `rm -f $$tmpfile` on a `mktemp` file | Own temp artifact |
| `tests/**` (e2e, integration, config, scripts) | `rm -f/-rf` on self-created response bodies, headers, temp dirs | Test temp artifacts |

### Bounded ClickHouse helper tables (deliberate, ephemeral by design)

| Location | Operation | Classification |
| --- | --- | --- |
| `res/scripts/backfill-reasoning-tokens.sh:145,252` | `DROP TABLE IF EXISTS ${DB}.reasoning_backfill` | Helper table created by the same script for backfill bookkeeping; not application data |
| `res/scripts/dedupe-model-history.sh:160,166` | `DROP TABLE [IF EXISTS] ${DB}.request_log_dedup` | Same pattern: dedupe helper table owned by the script; final drop prints the manual command rather than executing it where data may be present |

Both scripts target only their own helper tables; no application table
(`request_log`, `usage`, `reasoning`, etc.) is ever dropped or truncated.

### Compose lifecycle

| Location | Operation | Classification |
| --- | --- | --- |
| `Makefile:_compose-down` | `gateway-compose.sh down` (no args) | Container-only teardown; volumes preserved |
| `res/scripts/gateway-compose.sh:down` | `compose down "$@"` forwarding caller args | **Was an open volume-destruction path**: `down -v`/`--volumes` would delete every named volume including ClickHouse data |
| `Makefile:gw-undeploy` | disable + remove the user systemd unit | Unit files only; no container or volume deletion |
| `res/scripts/gateway-compose.sh:restart-service` | `podman restart` one enumerated container by fixed service allowlist | No deletion |

### Finding and remediation

`res/scripts/gateway-compose.sh` forwarded unvalidated arguments to
`podman-compose down`. The remediation lifecycle work removed every `down -v`
call site, but the wrapper itself still accepted the flag from a manual
invocation. Fixed in this change set: the `down` case now rejects `-v`,
`--volumes`, combined forms, and `--rmi-all` before invoking compose, with an
explicit error naming the persistent-data reason. Positive suite
(`tests/scripts/test_gateway_compose.sh`) and the negative probe
(`COMPOSE_BIN=/bin/true gateway-compose.sh down -v` fails with the refusal
message) both verified 2026-08-21.

## Boundary

This audit covers WORKSPACE-GATEWAY only. WORKSPACE-CI is covered by
`WORKSPACE-CI/docs/audits/AUDIT-CI-DESTRUCTIVE-PATHS-2026-08-21.md`;
WORKSPACE-GUARD remains open.
