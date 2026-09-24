# SPEC-GATEWAY-GOVERNANCE: Control Surface Implementation

**Date:** 2026-09-23
**Status:** Draft
**Type:** Specification
**Requirements:** [REQ-GATEWAY-GOVERNANCE](../requirements/REQ-GATEWAY-GOVERNANCE.md)

> Intended implementation of gateway governance: authorize privileged control
> actions with native `authz-keycloak`, delegate roles to Keycloak and the
> WORKSPACE-PORTAL, persist an audit trail, and expose **no** custom identity or
> credential UI. Configuration-only; not deployed.

---

**Cross-references:**
- [REQ-GATEWAY-GOVERNANCE](../requirements/REQ-GATEWAY-GOVERNANCE.md): requirements contract
- [SPEC-KEYCLOAK-INTEGRATION](SPEC-KEYCLOAK-INTEGRATION.md): `openid-connect` + `authz-keycloak` setup
- [AUTH-MODEL](../architecture/AUTH-MODEL.md): credential/identity model
- [RUNBOOK-KEYS](../runbooks/RUNBOOK-KEYS.md): key/pool operations to be governed
- [SPEC-SECURITY-HARDENING](SPEC-SECURITY-HARDENING.md): grant boundaries
- WORKSPACE-PORTAL `SPEC-AUTHORIZATION`: permission registry (external)

---

## 1. Overview

Governance is a thin authorization + audit layer over operations that already
exist (`gateway-key.sh`, `issue-key.sh`, `revoke-key.sh`, `pool-key.sh`).
Identity and role
management stay in Keycloak/portal; the gateway only enforces permissions and
records what happened.

```
Operator (portal / console)
  | Keycloak JWT with role/permission
  v
Governance surface (portal-mediated, or APISIX route with authz-keycloak)
  |-- authz-keycloak  (decision: allow/deny)
  |-- control action  --> OpenBao (key/pool record) + audit record
  v
ClickHouse audit (actor, action, target, timestamp)
```

## 2. Architectural Principles

### 2.1 Delegate, never duplicate
Identity, users, and roles live in Keycloak; permissions align with the portal
registry. The gateway holds no user/role tables.

### 2.2 Permission at the edge
`authz-keycloak` is the enforcement point. Deny by default (`ENFORCING`).

### 2.3 Auditable by construction
A control action is not "done" until its audit record is written.

### 2.4 No credential UI
Login is Keycloak; the gateway never renders or stores credentials.

## 3. Control Action and Permission Map

| Action | Existing interface | Required permission |
|--------|--------------------|---------------------|
| Issue virtual key | `res/scripts/issue-key.sh` | `gateway:keys:manage` |
| Revoke virtual key | `res/scripts/revoke-key.sh` | `gateway:keys:manage` |
| List keys | `res/scripts/list-keys.sh` | `gateway:keys:read` |
| View key record + upstream mapping | `res/scripts/gateway-key.sh show` | `gateway:keys:read` |
| Change key upstream mapping | `res/scripts/gateway-key.sh map` | `gateway:keys:manage` |
| Pool create/add/remove/enable/disable/reset | `res/scripts/pool-key.sh` | `gateway:pools:manage` |
| Pool list | `res/scripts/pool-key.sh list` | `gateway:pools:read` |
| Telemetry read (usage/cost) | Grafana / mediated query | `gateway:telemetry:read` |
| Conversation-body read | operator loopback only | not delegated (REQ-SECURITY-HARDENING FR-3.5) |

Permission names MUST be reconciled with WORKSPACE-PORTAL's `resource:action`
registry; where the portal already defines an equivalent, reuse it.

## 4. `authz-keycloak` Configuration

```yaml
plugins:
  authz-keycloak:
    token_endpoint: "http://keycloak:8080/realms/workspace/protocol/openid-connect/token"
    resource_registration_endpoint: "http://keycloak:8080/realms/workspace/authz/protection/resource_set"
    client_id: "llm-gateway"
    client_secret: "{{vault:secret/oidc/llm_gateway_client_secret}}"
    policy_enforcement_mode: "ENFORCING"
    permissions: ["gateway:keys:manage"]
```

Decision: allow only if the validated token carries the required permission
(Keycloak Authorization Services or a role claim mapped in Keycloak).

## 5. Audit Record

Minimum fields written on every control action:

| Field | Source |
|-------|--------|
| `actor_sub` | Keycloak `sub` of the caller |
| `actor_azp` | Keycloak `azp` |
| `action` | issue / revoke / pool-add / pool-remove / enable / disable / reset |
| `target` | virtual key id or pool/key id |
| `outcome` | allow / deny |
| `timestamp` | UTC |

Storage: prefer the existing telemetry plane (ClickHouse) with a dedicated
table granted to the audit writer; bodies are never included.

## 6. Delegated Administration Flow

```
Admin assigns role/permission  -->  Keycloak (Admin Console) / PORTAL
User performs control action   -->  portal or APISIX route
                                    authz-keycloak checks the token
                                    action runs against OpenBao
                                    audit record written
```
The gateway never manages users or roles; removing a role in Keycloak removes
the gateway capability on the next token.

## 7. Edge Cases & Decisions

- **Scripts vs API:** the existing scripts remain the mechanism; governance adds
  an authorization wrapper, not a rewrite. If a gateway API is required, it is a
  portal-mediated gateway call, not a new admin UI.
- **Break-glass:** operator loopback `ops_admin`/`OPENBAO_TOKEN` access remains
  for recovery, out of band from Keycloak (consistent with security hardening).
- **Permission drift:** if the portal registry changes, the map in §3 is updated
  in the same change.

## 8. File Map

| File | Purpose | Key Changes |
|------|---------|-------------|
| `conf/apisix.yaml` (planned) | governance routes with `authz-keycloak` | add when adopted |
| `res/scripts/*.sh` (planned) | record actor identity on control actions | add `--actor` / env |
| ClickHouse migration (planned) | control-action audit table | new migration if adopted |
| `docs/architecture/AUTH-MODEL.md` | identity/authorization model | new |

## 9. Implementation Status

| Component | Status | Evidence |
|-----------|--------|----------|
| `authz-keycloak` governance routes | Not implemented | no `authz-keycloak` in `conf/` |
| Control-action permission map | Design only | §3 |
| Audit table/records | Not implemented | no control-action audit |
| Delegated roles | Not implemented | no Keycloak role consumption |
| Tests | Not implemented | no `tests/**` referencing governance |
