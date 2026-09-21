# REQ-SECURITY-HARDENING: Exposure, AuthN/Z, and Retention Hardening

**Date:** 2026-09-20
**Status:** Active
**Type:** Requirements
**Specification:** [SPEC-SECURITY-HARDENING](../specifications/SPEC-SECURITY-HARDENING.md)

> Mandates the 2026-09 exposure hardening: ClickHouse per-service accounts with least-privilege grants (passwordless network `default` eliminated), conversation-body isolation into a dedicated ungranted table, tiered-compression retention (no deletion TTLs) with growth alerting, Grafana privilege-based lockdown (auth-proxy allowlist, secure cookies, rotated admin secret; Explore remains enabled  -  safety comes from grants), compose network segmentation with static subnets, removal of all non-data-plane host port publications, authenticated telemetry writers (Vector, sse-usage), etcd RBAC, edge-proxy trust contract, and secrets rotation. Single source of truth: [`res/docker/docker-compose.yml`](../../res/docker/docker-compose.yml), [`res/docker/clickhouse-provision.sh`](../../res/docker/clickhouse-provision.sh), [`conf/clickhouse-storage-tiering.xml`](../../conf/clickhouse-storage-tiering.xml), [`conf/migrations/`](../../conf/migrations), [`conf/vector.toml`](../../conf/vector.toml). Excluded: redaction semantics (REQ-REDACT), key lifecycle (RUNBOOK-KEYS), dashboard panel specs (REQ-DASHBOARD).

---

**Cross-references:**
- [SPEC-SECURITY-HARDENING](../specifications/SPEC-SECURITY-HARDENING.md): companion specification
- [REQ-BILLING-TELEMETRY](REQ-BILLING-TELEMETRY.md): schema contract this document amends (body split, retention)
- [REQ-DASHBOARD](REQ-DASHBOARD.md): Grafana requirements this document amends (datasource identity, growth panel)
- [RUNBOOK-EDGE-PROXY](../runbooks/RUNBOOK-EDGE-PROXY.md): edge trust contract (external component)
- [RUNBOOK-SECRETS](../runbooks/RUNBOOK-SECRETS.md): rotation procedures
- [AUDIT context](../audits/AUDIT-GATEWAY-AUTOMATION-2026-08.md): prior loopback-binding audit this extends

---

## 1. Purpose & Scope

### 1.1 Purpose
Guarantee that conversation content and other request telemetry cannot be
extracted through the public Grafana endpoint or any network-reachable
service except by explicitly authorized operators, while preserving all
existing features (dashboards, Explore, usefulness telemetry, backfills)
and retaining all telemetry data indefinitely at controlled storage cost.

### 1.2 Scope
**This document OWNS the requirements for:**
- ClickHouse authentication and per-service authorization (users, grants, host restrictions)
- Conversation-body storage isolation (`request_bodies` table, grant boundary)
- Retention policy: tiered compression instead of deletion TTLs, growth alerting
- Grafana trust model (auth-proxy allowlist, secure cookies/headers, admin secret)
- Compose network segmentation and the host port publication surface
- Telemetry writer authentication (Vector sink, sse-usage INSERT)
- etcd RBAC for the APISIX config plane
- Edge-proxy trust contract for `X-WEBAUTH-USER`
- Secrets inventory and rotation

**This document DOES NOT:**
- Define what PII is tokenized in-flight (REQ-REDACT)
- Define virtual key lifecycle in OpenBao (RUNBOOK-KEYS)
- Define dashboard panel layouts (REQ-DASHBOARD / SPEC-DASHBOARD)
- Operate the external edge proxy itself (outside this repository; contract only)

### 1.3 Terminology
| Term | Definition |
|------|------------|
| Data plane | APISIX listeners 9080/9443 (dev) and 9081/9444 (prod); the only host-published service ports besides loopback ClickHouse HTTP and Grafana |
| Body table | `llm_gateway.request_bodies`; sole store of `req_body`/`resp_body` after the split |
| Tiered storage | ClickHouse storage policy `tiered`: hot volume on the default disk, `archive` volume recompressed with `CODEC ZSTD(3)`; no `TTL ... DELETE` |
| Auth-proxy | Grafana authentication mode trusting `X-WEBAUTH-USER` set by the edge proxy |
| Edge proxy | External nginx ("wiki nginx") terminating `https://workspaceguardrails.com` and forwarding `/grafana/` to `gw-grafana:3000` over the `gw-edge` network |
| gw-ch | Dedicated compose network carrying ClickHouse client traffic; static subnet per stack |
| gw-edge | Dedicated compose network carrying only Grafana and the pinned external edge proxy (`10.99.60.2`); the sole source Grafana trusts `X-WEBAUTH-USER` from |

## 2. Functional Requirements

### FR-1: ClickHouse Authentication
| ID | Requirement |
|----|-------------|
| FR-1.1 | ClickHouse MUST provision per-service users (env-driven, idempotent, re-runnable via `make ch-provision`): `grafana_ro`, `vector_rw`, `apisix_rw`, `migrator` via [`res/docker/clickhouse-provision.sh`](../../res/docker/clickhouse-provision.sh); `ops_admin` as a static `conf/clickhouse-users.d/ops-admin.xml` user (password from env, `access_management` on) so a bootstrap admin exists before first provisioning run. |
| FR-1.2 | The `default` user MUST NOT accept passwordless connections from any network; it MUST carry a strong password from `CLICKHOUSE_PASSWORD` and be restricted to localhost (in-container) connections. `CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT` MUST remain unset  -  bootstrap admin duties belong to the `ops_admin` XML user. |
| FR-1.3 | All ClickHouse credentials MUST be injected via environment variables from `.env`; no credential value may appear in any committed file. |
| FR-1.4 | `ops_admin` MUST be the only account with full privileges and MUST only accept connections from the host-forwarded source address (gw-ch gateway) and localhost. |

### FR-2: ClickHouse Authorization (grant boundaries)
| ID | Requirement |
|----|-------------|
| FR-2.1 | `grafana_ro` MUST be `readonly = 1` with `allow_ddl = 0`, granted `SELECT` on `llm_gateway.*` plus `SELECT` on `system.parts`, `system.disks`, `system.tables` (growth panel only); it MUST NOT be granted anything on `request_bodies`. |
| FR-2.2 | `vector_rw` MUST be granted `INSERT` on `llm_gateway.request_log` and `llm_gateway.request_bodies` only. |
| FR-2.3 | `apisix_rw` MUST be granted `INSERT` on `llm_gateway.usage_log` only. |
| FR-2.4 | `migrator` MUST be granted full DDL/DML on `llm_gateway.*` only. |
| FR-2.5 | Every provisioned user MUST carry a `HOST` restriction to the gw-ch subnet (in-stack clients), the gw-ch gateway (host-forwarded ops clients), or localhost, as appropriate to its role. |

### FR-3: Conversation-Body Isolation
| ID | Requirement |
|----|-------------|
| FR-3.1 | `req_body` and `resp_body` MUST live in `llm_gateway.request_bodies` (join keys `event_id`, `request_id`); `request_log` MUST NOT contain body columns after migration. |
| FR-3.2 | Historical bodies MUST be copied into `request_bodies` before the `request_log` body columns are dropped; the drop MUST be gated on a row-count parity check. |
| FR-3.3 | Vector MUST write both tables from the single remap output (one transform, two sinks; `skip_unknown_fields` routes columns). |
| FR-3.4 | Grafana-visible SQL (any query executed under `grafana_ro`) MUST NOT be able to read conversation bodies, even though Explore remains enabled. |
| FR-3.5 | Operator access to bodies MUST go through `ops_admin` (host loopback `clickhouse-client` / scripts), never through a Grafana datasource. |

### FR-4: Retention and Storage Tiering
| ID | Requirement |
|----|-------------|
| FR-4.1 | All `TTL ... DELETE` clauses (13-month retention) MUST be removed from every `llm_gateway` table; telemetry data is retained indefinitely. |
| FR-4.2 | Tables MUST use storage policy `tiered` (`conf/clickhouse-storage-tiering.xml`): parts move to the `archive` volume (path inside the existing data volume) and are recompressed with `CODEC ZSTD(3)` on the schedule in migration `000011` (bodies at 6 months, metadata at 12/18 months). |
| FR-4.3 | A storage-growth panel (bytes on disk per table, free space, part counts from `system.parts`/`system.disks`) MUST exist on `gateway-ops-health`, and a Grafana unified alert MUST fire on low free space (<20%) or anomalous growth. |
| FR-4.4 | The reconciler MUST emit a warning when ClickHouse data growth exceeds the configured monthly budget. |
| FR-4.5 | Nightly ClickHouse backups MUST be written to `/mnt/ws-backup` (10.9T FUSE volume) via a systemd timer; the archive tier MUST NOT live on the FUSE volume (unsupported for live MergeTree). |

### FR-5: Grafana Trust Model
| ID | Requirement |
|----|-------------|
| FR-5.1 | Grafana MUST authenticate via auth-proxy (`X-WEBAUTH-USER`) restricted by `GF_AUTH_PROXY_WHITELIST` to the edge proxy's pinned `gw-edge` address (`10.99.60.2`) and localhost. |
| FR-5.2 | Anonymous auth MUST be disabled in every environment; the dev override MUST be removed from compose defaults and test fixtures. |
| FR-5.3 | `GF_SECURITY_ADMIN_PASSWORD` MUST be a strong rotated secret (never the factory `admin`). |
| FR-5.4 | Grafana MUST set secure cookies (`GF_SECURITY_COOKIE_SECURE=true`), HSTS, and disable version/usage telemetry reporting. |
| FR-5.5 | The ClickHouse datasource MUST use `grafana_ro` with its password injected via provisioning `secureJsonData` from environment; the datasource stays `editable: false`. |
| FR-5.6 | Explore MUST remain enabled (feature preservation); the control against arbitrary SQL is the FR-2.1 grant boundary, not UI removal. |

### FR-6: Network Segmentation and Port Surface
| ID | Requirement |
|----|-------------|
| FR-6.1 | The flat `gateway` network MUST be replaced by per-function networks with static subnets: `gw-ch` (clickhouse, apisix, vector, grafana, migrate), `gw-etcd` (apisix, etcd), `gw-secrets` (apisix, openbao), `gw-metrics` (apisix, prometheus, grafana), `gw-ingest` (apisix, vector), `gw-edge` (grafana + the external edge proxy, pinned at `10.99.60.2`). `dataops_default` dual-homing of apisix is unchanged. |
| FR-6.2 | Published host ports MUST be exactly: `9080/9443` (dev apisix), `9081/9444` (prod apisix), loopback `8123` (dev ClickHouse HTTP), loopback `8124` (prod ClickHouse HTTP), loopback `3030` (Grafana). All other host port publications (etcd 2379/2380, OpenBao 8201, vector 18080, apisix admin 9180/9181, apisix metrics 9100/9101, ClickHouse native 9000/9001) MUST be removed. |
| FR-6.3 | In-stack access to unpublished services MUST be via `podman exec` / compose DNS only. |
| FR-6.4 | The prod stack MUST mirror the same segmentation with its own static subnets and remain fully isolated from dev volumes/ports. |

### FR-7: Authenticated Telemetry Writers
| ID | Requirement |
|----|-------------|
| FR-7.1 | The Vector ClickHouse sink MUST authenticate (HTTP basic auth) as `vector_rw` via env-interpolated credentials. |
| FR-7.2 | The `sse-usage` plugin MUST authenticate its `usage_log` INSERTs as `apisix_rw`: route config carries `clickhouse_user` and `clickhouse_password_env` (env resolved at request time, following the `openbao_token_env` pattern); the password env MUST be declared in `nginx_config.envs`. |
| FR-7.3 | The golang-migrate DSN (`make ch-migrate`, compose `migrate` service) MUST authenticate as `migrator`. |
| FR-7.4 | Every host-side ClickHouse client script (reconciler, crunch-usefulness, sync-model-registry, backfill-reasoning-tokens, seed-clickhouse-dashboard-data, dedupe-model-history, migrate-opencode-stats) MUST send `ops_admin` basic auth from env (`CH_OPS_USER`/`CH_OPS_PASSWORD`), with no unauthenticated access. |

### FR-8: etcd RBAC
| ID | Requirement |
|----|-------------|
| FR-8.1 | etcd MUST run with authentication enabled; the APISIX config plane MUST authenticate as a dedicated non-root user (`ETCD_GW_USER`), injected into [`conf/config.yaml`](../../conf/config.yaml) via env expansion. |
| FR-8.2 | The root etcd credential MUST exist only in `.env` for bootstrap (`make etcd-auth-init`). |

### FR-9: Edge-Proxy Trust Contract
| ID | Requirement |
|----|-------------|
| FR-9.1 | The edge proxy MUST strip any inbound client-supplied `X-WEBAUTH-USER` before authenticating the caller and setting its own value; this is a hard contract documented in RUNBOOK-EDGE-PROXY with a verification matrix. |
| FR-9.2 | The gateway repository MUST ship the verification matrix (spoofed-header rejection, ClickHouse/Prometheus unreachability, auth-proxy allowlist) so the contract is testable end-to-end from this side. |

### FR-10: Secrets Rotation
| ID | Requirement |
|----|-------------|
| FR-10.1 | `ADMIN_KEY` (previously the public APISIX demo value), `GRAFANA_ADMIN_PASSWORD` (previously `admin`), `OPENCODE_API_KEY`, and `OPENBAO_TOKEN` MUST be rotated per RUNBOOK-SECRETS as part of this hardening. |
| FR-10.2 | `.env.example` MUST enumerate every variable with example values and no real secrets; `.env` MUST stay gitignored with `0600` permissions. |

## 3. Non-Functional Requirements
| ID | Requirement |
|----|-------------|
| NFR-1.1 | No existing feature may be removed: dashboards, Explore, usefulness telemetry, backfills, prod staging stack all keep working under the new controls. |
| NFR-1.2 | Credential rollout MUST be order-safe: clients are updated and verified against a still-permissive bootstrap before `default` is locked; no telemetry write path may drop data without notice. |
| NFR-1.3 | All hardening config MUST be declarative (compose, XML, SQL, env) and reversible without volume loss. |
| NFR-1.4 | Failure of the growth-alerting path MUST NOT affect data-plane or telemetry writes. |

## 4. Constraints
| ID | Constraint | Source |
|----|-----------|--------|
| C-1 | `/mnt/ws-backup` is uid=0 fuseblk (NTFS); unsuitable as a live ClickHouse disk; backup target only | RUNBOOK-SECRETS / host facts |
| C-2 | ClickHouse 24.8 cannot MODIFY ORDER BY on populated MergeTree | REQ-BILLING-TELEMETRY C-2 |
| C-3 | Grafana OSS has no per-datasource permissions; all org users see all datasources  -  hence grant-based isolation | SPEC-SECURITY-HARDENING |
| C-4 | The edge proxy configuration is outside this repository; only the contract and verification matrix are in-repo | RUNBOOK-EDGE-PROXY |
| C-5 | `docs/architecture/TELEMETRY-AND-SCHEMA.md` path is critical for tests | tests/config/test_migrations.sh |

## 5. Assumptions
| ID | Assumption |
|----|------------|
| A-1 | The edge proxy is a container and reaches Grafana over the dedicated `gw-edge` bridge (it cannot reach host loopback: rootless podman runs `slirp4netns --disable-host-loopback`); Grafana's auth-proxy trusts the proxy's pinned `gw-edge` address. |
| A-2 | The edge proxy admin will apply the RUNBOOK-EDGE-PROXY strip rule in the same rollout window. |
| A-3 | ws-backup's existing root write path (cron/systemd) is available to host the nightly backup job. |

## 6. Open Questions
| Q | A |
|---|---|
| Column-level grants instead of table split? | Not supported cleanly in ClickHouse 24.8; table split chosen. |
| Encrypted volume at rest? | Deferred by operator decision (2026-09-20); revisit if threat model changes. |

## 7. Verification Matrix
| # | Test | Maps to |
|---|------|---------|
| V1 | `tests/config/test_compose.sh`  -  networks, subnets, published-port surface, Grafana env | FR-5.x, FR-6.x |
| V2 | `tests/config/test_clickhouse_auth.sh`  -  provision script, grant boundary, `default` lockout | FR-1.x, FR-2.x |
| V3 | `tests/config/test_vector_toml.sh`  -  authenticated dual sinks | FR-3.3, FR-7.1 |
| V4 | `tests/config/test_apisix_yaml.sh`  -  sse-usage auth fields on all routes | FR-7.2 |
| V5 | `tests/config/test_migrations.sh`  -  000010/000011 contents, tiering XML | FR-3.x, FR-4.x |
| V6 | `tests/config/test_grafana_provisioning.sh`  -  datasource identity, env-injected password, growth panel | FR-5.5, FR-4.3 |
| V7 | `tests/e2e/test_security_lockdown.sh`  -  live matrix: unauth CH 401, `grafana_ro` DDL/INSERT denied, body table invisible, spoofed `X-WEBAUTH-USER` rejected | FR-2.x, FR-3.4, FR-9.2 |
| V8 | `tests/config/test_etcd_auth.sh`  -  etcd auth config, APISIX user wiring | FR-8.x |

## 8. Implementation Status
| Item | Status | Evidence |
|------|--------|----------|
| FR-1.x-FR-10.x | In progress (2026-09-20 hardening change) | SPEC-SECURITY-HARDENING File Map |
