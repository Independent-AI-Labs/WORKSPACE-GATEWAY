# REQ-GATEWAY-GOVERNANCE: Control Surface and Delegated Administration

**Date:** 2026-09-23
**Status:** Draft
**Type:** Requirements
**Specification:** [SPEC-GATEWAY-GOVERNANCE](../specifications/SPEC-GATEWAY-GOVERNANCE.md)

> Defines who may perform gateway control actions (virtual-key lifecycle,
> upstream-pool management, telemetry read) and how those decisions are
> authorized  -  by delegating identity and authorization to Keycloak (via
> [REQ-KEYCLOAK-INTEGRATION](REQ-KEYCLOAK-INTEGRATION.md)) and the
> WORKSPACE-PORTAL RBAC vocabulary, with **no custom identity or credential
> UI**. **Not implemented**: today these actions are performed by host-side
> scripts (`issue-key.sh`, `revoke-key.sh`, `pool-key.sh`) with no gateway-level
> authorization.

---

**Cross-references:**
- [SPEC-GATEWAY-GOVERNANCE](../specifications/SPEC-GATEWAY-GOVERNANCE.md): companion specification
- [REQ-KEYCLOAK-INTEGRATION](REQ-KEYCLOAK-INTEGRATION.md): identity/authorization provider
- [AUTH-MODEL](../architecture/AUTH-MODEL.md): credential model
- [KEY-MANAGEMENT](../architecture/KEY-MANAGEMENT.md) / [RUNBOOK-KEYS](../runbooks/RUNBOOK-KEYS.md): key + pool lifecycle
- [REQ-DASHBOARD](REQ-DASHBOARD.md): telemetry read surface
- [REQ-SECURITY-HARDENING](REQ-SECURITY-HARDENING.md): Grafana trust model, grant boundaries
- WORKSPACE-PORTAL `SPEC-AUTHORIZATION` / `REQ-IAM`: permission registry (external)

---

## 1. Purpose & Scope

### 1.1 Purpose

Make gateway administration a governed, auditable activity tied to corporate
identity, without building a parallel identity system or admin UI. Every
privileged action maps to a Keycloak role/permission and is attributable to a
person or service.

### 1.2 Scope

**This document OWNS the requirements for:**
- The set of privileged gateway control actions and their authorization
- Delegation of roles/permissions to Keycloak (not local tables)
- Auditability of administrative actions
- The rule that no custom credential-entry / identity UI is built
- The read surface for telemetry (who can see what)

**This document DOES NOT:**
- Implement OIDC validation (REQ-KEYCLOAK-INTEGRATION)
- Define the OpenBao key record schema (KEY-MANAGEMENT)
- Define dashboard panel content (REQ-DASHBOARD)
- Operate Keycloak or the portal (external projects)

### 1.3 Terminology

| Term | Definition |
|------|------------|
| Control action | A state-changing gateway operation: issue/revoke key, pool add/remove/enable/disable/reset |
| Governance read | Reading usage/cost/audit telemetry through a gateway-mediated surface |
| Delegated admin | A portal/console user whose authority comes from Keycloak roles |
| Permission | A `resource:action` grant, aligned with the portal registry where feasible |

## 2. Functional Requirements

### FR-1: Authorized Control Actions

| ID | Requirement |
|----|-------------|
| FR-1.1 | Every control action MUST require an authenticated Keycloak identity and an explicit permission (`gateway:keys:manage`, `gateway:pools:manage`, ...). |
| FR-1.2 | The permission vocabulary MUST align with WORKSPACE-PORTAL's `resource:action` registry; where a match exists, reuse it rather than inventing a parallel name. |
| FR-1.3 | Authorization MUST be evaluated by the native `authz-keycloak` plugin; no local role tables. |
| FR-1.4 | Unauthorized control actions MUST return 403; unauthenticated MUST return 401. |

### FR-2: Auditability

| ID | Requirement |
|----|-------------|
| FR-2.1 | Every control action MUST record actor identity (`sub`/`azp`), action, target, and timestamp. |
| FR-2.2 | Audit records MUST be queryable by authorized operators and MUST NOT be mutable without leaving an audit record. |
| FR-2.3 | Control-action audit MUST share the identity attributes used for telemetry attribution (AUTH-MODEL). |

### FR-3: Delegated Administration via Portals

| ID | Requirement |
|----|-------------|
| FR-3.1 | Role assignment and user management MUST be performed in Keycloak (Admin Console) and/or the WORKSPACE-PORTAL; the gateway MUST NOT expose user/role CRUD. |
| FR-3.2 | The gateway MUST accept roles/claims issued by Keycloak and MUST NOT maintain a divergent role model. |
| FR-3.3 | If a governance view is exposed through the portal or a gateway surface, it MUST be authorization-enforced by Keycloak permissions. |

### FR-4: Telemetry Read Governance

| ID | Requirement |
|----|-------------|
| FR-4.1 | Access to usage/cost telemetry MUST be bounded by grants (ClickHouse `grafana_ro` today) and/or Keycloak permissions for mediated surfaces. |
| FR-4.2 | Conversation bodies MUST remain operator-only (never exposed through shared dashboards), consistent with REQ-SECURITY-HARDENING FR-3.4. |

### FR-5: No Custom Identity/Credential UI

| ID | Requirement |
|----|-------------|
| FR-5.1 | The project MUST NOT build a login form, user directory, or role editor. |
| FR-5.2 | Any gateway-provided governance page MUST delegate authentication to Keycloak and MUST NOT collect or store credentials. |

## 3. Non-Functional Requirements

| ID | Requirement |
|----|-------------|
| NFR-1.1 | Governance authorization MUST be configuration-only (native plugins + Keycloak config). |
| NFR-1.2 | Enabling governance MUST NOT alter data-plane behavior for existing routes. |
| NFR-1.3 | Control-action audit MUST survive the process that performed it (persisted, not in-memory only). |
| NFR-1.4 | The governance surface MUST fail closed on authorization errors. |

## 4. Constraints

| ID | Constraint | Source |
|----|------------|--------|
| C-1 | Keycloak and the portal are external projects; the gateway consumes, never re-implements | DATAOPS/Portal ownership |
| C-2 | Today control actions are host-side scripts without gateway auth | `res/scripts/*.sh` |
| C-3 | Grafana OSS has no per-datasource permissions; isolation is grant-based | REQ-SECURITY-HARDENING C-3 |
| C-4 | Permission names should track the portal registry, which may evolve | WORKSPACE-PORTAL SPEC-AUTHORIZATION |

## 5. Assumptions

| ID | Assumption |
|----|------------|
| A-1 | Keycloak roles/permissions can express the gateway's control actions. |
| A-2 | The portal registry (or Keycloak Authorization Services) is the canonical permission source. |
| A-3 | Audit storage is available (ClickHouse) and grantable. |

## 6. Open Questions

| Q | Resolution |
|---|------------|
| Mediated governance API vs portal-only? | Prefer portal-only unless a gateway API is required; decide with WORKSPACE-PORTAL |
| Where does control-action audit land (ClickHouse table vs log)? | Decide at adoption; reuse existing telemetry plane if possible |
| Are gateway permissions portal client roles or Keycloak Authorization resources? | Align with portal `SPEC-AUTHORIZATION` decision |

## 7. Verification Matrix

| # | Test | Maps to |
|---|------|---------|
| V1 | Unauthenticated control action -> 401; unauthorized -> 403 | FR-1.1, FR-1.4 |
| V2 | Authorized control action succeeds and records actor/action/target | FR-2.1 |
| V3 | No user/role CRUD exposed by the gateway | FR-3.1, FR-5.1 |
| V4 | Telemetry read is grant-bounded; bodies remain operator-only | FR-4.1, FR-4.2 |
| V5 | No custom login/credential UI code present | FR-5.1, FR-5.2 |

## 8. Implementation Status

| Item | Status | Evidence |
|------|--------|----------|
| FR-1.x authorized control actions | Not implemented | scripts run host-side with no gateway authz |
| FR-2.x control-action audit | Not implemented | no actor identity on `issue-key`/`pool-key` actions |
| FR-3.x delegated administration | Not implemented | no Keycloak role consumption at gateway |
| FR-4.x telemetry read governance | Partial | `grafana_ro` grant boundary exists (REQ-SECURITY-HARDENING) |
| FR-5.x no custom identity UI | Design decision | no identity UI in repo |
| Tests | Not implemented | no `tests/**` referencing governance |
