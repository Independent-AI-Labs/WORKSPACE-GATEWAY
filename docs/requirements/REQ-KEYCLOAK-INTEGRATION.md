# REQ-KEYCLOAK-INTEGRATION: Inbound Identity and Authorization

**Date:** 2026-09-23
**Status:** Draft
**Type:** Requirements
**Specification:** [SPEC-KEYCLOAK-INTEGRATION](../specifications/SPEC-KEYCLOAK-INTEGRATION.md)

> Defines how the gateway consumes the **existing** WORKSPACE Keycloak realm
> (`workspace`, client `workspace-portal`, deployed by WORKSPACE-DATAOPS) for
> inbound user/service identity and authorization, using APISIX's native
> `openid-connect` and `authz-keycloak` plugins  -  never a home-grown OIDC
> validator. This document is the successor to the OIDC half of
> [REQ-ENTERPRISE-AUTH](REQ-ENTERPRISE-AUTH.md) (Retired). **Not implemented in
> the current deployment**: the gateway today authenticates the data plane with
> `key-resolver` virtual keys, provider `provider-oauth`, and shared-key
> passthrough. See [AUTH-MODEL](../architecture/AUTH-MODEL.md) for the full
> credential model and [REQ-GATEWAY-GOVERNANCE](REQ-GATEWAY-GOVERNANCE.md) for
> the control surface.
>
> Boundary: the custom `provider-oauth` plugin is **outbound** provider OAuth
> (device/browser flows that broker *upstream* provider tokens). It is not an
> inbound identity validator and does not overlap `openid-connect`.

---

**Cross-references:**
- [SPEC-KEYCLOAK-INTEGRATION](../specifications/SPEC-KEYCLOAK-INTEGRATION.md): companion specification
- [AUTH-MODEL](../architecture/AUTH-MODEL.md): credential model this document feeds
- [REQ-GATEWAY-GOVERNANCE](REQ-GATEWAY-GOVERNANCE.md): control surface built on this identity layer
- [KEY-MANAGEMENT](../architecture/KEY-MANAGEMENT.md): OpenBao virtual-key lifecycle
- [REQ-SECURITY-HARDENING](REQ-SECURITY-HARDENING.md): trust boundaries, `dataops_default` dual-homing (FR-6.1)
- WORKSPACE-DATAOPS `SPEC-IAM` / `REQ-IAM`: Keycloak deployment and client provisioning (external)
- WORKSPACE-PORTAL `SPEC-AUTHORIZATION` / `REQ-IAM`: RBAC registry and role vocabulary (external)

---

## 1. Purpose & Scope

### 1.1 Purpose

Let the gateway trust the Keycloak realm already operated by WORKSPACE-DATAOPS
as the single source of user and service identity, so that gateway operators and
API callers authenticate against one corporate identity  -  with authorization
enforced at the gateway using native APISIX plugins and no custom identity
code.

### 1.2 Scope

**This document OWNS the requirements for:**
- Inbound OIDC bearer-token validation (`openid-connect`, native)
- Claim-to-context mapping (`sub`, `groups`, `realm_access.roles`) onto the
  existing `X-Gateway-*` context headers
- Fine-grained authorization for control/governance endpoints (`authz-keycloak`)
- Binding of long-lived virtual keys (`vgw-*`) to a Keycloak identity
- Consumption of DATAOPS as the sole Keycloak provisioner (no local realm JSON)
- Gateway use of Keycloak-issued JWTs to authenticate to OpenBao

**This document DOES NOT:**
- Operate or configure Keycloak itself (WORKSPACE-DATAOPS owns the deployment)
- Define the permission vocabulary or portal UX (WORKSPACE-PORTAL `SPEC-AUTHORIZATION`)
- Define virtual-key/pool storage schema (KEY-MANAGEMENT / RUNBOOK-KEYS)
- Cover outbound provider credential acquisition (`provider-oauth`, SPEC-PROVIDER-*)
- Replace the data-plane virtual-key path; OIDC is additive

### 1.3 Terminology

| Term | Definition |
|------|------------|
| Realm | Keycloak security domain `workspace` (issuer `<base>/realms/workspace`) |
| Client | Keycloak OIDC client; the gateway's own client is requested as `llm-gateway` |
| Bearer-only | `openid-connect` resource-server mode: validate a JWT, no browser redirect |
| Virtual key | Long-lived `vgw-*` credential resolved by `key-resolver` |
| Control surface | Operator-facing actions: key issue/revoke, pool management, telemetry read |
| DWK | DATAOPS-provided discovery URL: `http://keycloak:8080/realms/workspace/.well-known/openid-configuration` |

## 2. Functional Requirements

### FR-1: Inbound OIDC Validation

| ID | Requirement |
|----|-------------|
| FR-1.1 | Inbound user/service authentication MUST use the native `openid-connect` plugin in `bearer_only: true` mode against the DATAOPS realm discovery URL. No custom JWT validator may be added. |
| FR-1.2 | The plugin MUST validate signature (JWKS from discovery, cached), expiry, issuer, audience, and scope. |
| FR-1.3 | Claims MUST map onto the existing context headers: `sub` -> `X-Gateway-User-Id`, `azp` -> `X-Gateway-Client-Id`, selected organization/`groups` claim -> `X-Gateway-Tenant-Id`, `realm_access.roles` -> authorization input. |
| FR-1.4 | The inbound access token MUST NOT be forwarded upstream (`access_token_in_authorization_header: false`); the gateway always injects the resolved upstream provider credential. |
| FR-1.5 | Authentication failures MUST fail closed: missing Bearer -> 401; expired/invalid token -> 401; cold-start JWKS unreachable -> 401; wrong audience/scope -> 403. |
| FR-1.6 | Multi-issuer support, if ever required, MUST use one plugin instance per issuer (route/Host scoped), never issuer-sniffing custom code. |

### FR-2: Fine-Grained Authorization

| ID | Requirement |
|----|-------------|
| FR-2.1 | Control-surface endpoints (governance API, key lifecycle, telemetry read) MUST be authorized with the native `authz-keycloak` plugin against Keycloak Authorization Services permissions. |
| FR-2.2 | Data-plane LLM routes MAY be authenticated by OIDC and/or virtual key; when both are present the resolved identity MUST be one of the two credential classes in [AUTH-MODEL](../architecture/AUTH-MODEL.md)  -  never a third scheme. |
| FR-2.3 | Authorization decisions MUST be based on roles/claims issued by Keycloak, not on locally maintained role tables. |

### FR-3: Virtual-Key Identity Binding

| ID | Requirement |
|----|-------------|
| FR-3.1 | Every `vgw-*` virtual key MUST be associated with a Keycloak identity (at minimum `sub` or `azp`; organization when applicable) recorded in its OpenBao record. |
| FR-3.2 | Virtual keys MUST be stored hashed (or referenced such that the plaintext key is not readable from the store record) and remain revocable via the existing `revoke-key` path. |
| FR-3.3 | Telemetry rows produced under a virtual key MUST carry the bound identity so usage can be attributed to a Keycloak user/client. |
| FR-3.4 | Key issuance MUST NOT require a second identity store; identity attributes are looked up from Keycloak/DATAOPS, not duplicated. |

### FR-4: Provisioning Ownership

| ID | Requirement |
|----|-------------|
| FR-4.1 | The gateway MUST consume a Keycloak OIDC client provisioned by WORKSPACE-DATAOPS (request: `llm-gateway`), per DATAOPS `REQ-IAM` FR-15. |
| FR-4.2 | The gateway repository MUST NOT ship a realm JSON export, a Keycloak container, or a Keycloak compose service. |
| FR-4.3 | Gateway software MUST reach Keycloak over the external `dataops_default` network already joined by `apisix`; no new host port is published. |
| FR-4.4 | Client secret / JWKS requirements MUST be delivered via the existing env/OpenBao mechanisms, never committed. |

### FR-5: OpenBao Integration

| ID | Requirement |
|----|-------------|
| FR-5.1 | `gw-openbao` remains authoritative for gateway secrets now; convergence onto the DATAOPS `workspace-openbao` service is a target-state, not a prerequisite. |
| FR-5.2 | Human/operator access to OpenBao SHOULD authenticate via Keycloak JWT (OIDC auth method, `bound_audiences` = the gateway client), not a static root token. |
| FR-5.3 | The gateway's request-path reads (virtual keys, upstream pools) MUST continue to use the service-scoped `OPENBAO_TOKEN`; per-user OpenBao tokens are for operators, not the data plane. |

### FR-6: No Custom Identity UI

| ID | Requirement |
|----|-------------|
| FR-6.1 | The project MUST NOT build a custom login, user, or role management UI; Keycloak Admin Console (operators) and Account Console (users) are the interfaces. |
| FR-6.2 | Any gateway-side governance view MUST be authorization-enforced by Keycloak roles and MUST NOT re-implement credential entry. |

## 3. Non-Functional Requirements

| ID | Requirement |
|----|-------------|
| NFR-1.1 | OIDC validation MUST be configuration-only (native `openid-connect`); no new custom Lua for token validation. |
| NFR-1.2 | Enabling OIDC MUST NOT change the behavior of existing deployed routes when the plugin is not attached. |
| NFR-1.3 | JWKS/token validation MUST not add more than a bounded per-request latency overhead (cached keys, no per-request network fetch on the hot path). |
| NFR-1.4 | The identity provider MUST be reachable over an in-stack network; a Keycloak outage MUST fail closed without cascading to already-authenticated virtual-key traffic unless that route opts into OIDC. |
| NFR-1.5 | Secrets (client secret, OpenBao token) MUST be env/vault references and MUST NOT appear in committed files. |

## 4. Constraints

| ID | Constraint | Source |
|----|------------|--------|
| C-1 | Keycloak is deployed by WORKSPACE-DATAOPS only; the gateway cannot provision realms/clients | DATAOPS `REQ-IAM` FR-15 |
| C-2 | Keycloak 26.2 runs `start-dev` (postgres-backed) under the DATAOPS `secrets` profile; the gateway does not control its lifecycle | DATAOPS compose (`keycloak`) |
| C-3 | The data plane authenticates primarily by virtual key today; OIDC is additive, not a replacement | KEY-MANAGEMENT |
| C-4 | `provider-oauth` is outbound provider OAuth and MUST NOT be repurposed as inbound auth | this document, FR-1.1 |
| C-5 | `dataops_default` is an external network; membership is a compose change, not a network creation | `res/docker/docker-compose.yml` |

## 5. Assumptions

| ID | Assumption |
|----|------------|
| A-1 | WORKSPACE-DATAOPS will provision the gateway OIDC client and expose discovery on `dataops_default`. |
| A-2 | The realm emits `groups`/`realm_access.roles`/organization claims sufficient for tenant mapping. |
| A-3 | The native APISIX build ships `openid-connect` and `authz-keycloak` (verified present in 3.18.0). |
| A-4 | Operators can reach the Admin Console; end users can reach the Account Console. |

## 6. Open Questions

| Q | Resolution |
|---|------------|
| Exact gateway client name and requested scopes/roles | Request `llm-gateway` via DATAOPS; confirm audience and role assignments before enabling `bearer_only` |
| Tenant mapping source (`groups` vs Organizations claim) | Decide when the DATAOPS mapper set is finalized; keep the mapping declarative (`claims_to_header`) |
| Should any data-plane route adopt OIDC first (pilot) | Pick a low-risk internal route before the public data plane |
| OpenBao JWT auth method rollout | Target-state; depends on FR-5.2 and DATAOPS `REQ-IAM` FR-11 |

## 7. Verification Matrix

| # | Test | Maps to |
|---|------|---------|
| V1 | Native plugin presence: `openid-connect` and `authz-keycloak` are registered/available | FR-1.1, A-3 |
| V2 | Missing/expired/invalid Bearer -> 401; wrong audience/scope -> 403; fail closed | FR-1.5 |
| V3 | Claims appear as `X-Gateway-User-Id`/`X-Gateway-Client-Id`/`X-Gateway-Tenant-Id`; inbound token stripped | FR-1.3, FR-1.4 |
| V4 | `authz-keycloak` denies a role without the required permission; allows one with it | FR-2.1, FR-2.3 |
| V5 | Issued virtual key record carries a bound Keycloak identity; telemetry reflects it | FR-3.1, FR-3.3 |
| V6 | No realm JSON / Keycloak service in the gateway repo; Keycloak reachable via `dataops_default` | FR-4.2, FR-4.3 |
| V7 | No custom identity UI or JWT-validator code present | FR-6.1, NFR-1.1 |

## 8. Implementation Status

| Item | Status | Evidence |
|------|--------|----------|
| FR-1.x `openid-connect` routes | Not implemented | no `openid-connect` in `conf/apisix.yaml` or registered plugin list |
| FR-2.x `authz-keycloak` | Not implemented | no `authz-keycloak` in `conf/` |
| FR-3.x virtual-key identity binding | Not implemented | OpenBao key record has `tenant_id`/`user_id` but no Keycloak `sub`/`azp` |
| FR-4.x DATAOPS client provisioning | Not requested | no `llm-gateway` client; gateway repo has no realm JSON |
| FR-5.x OpenBao JWT auth | Not implemented | `OPENBAO_TOKEN` service token only |
| FR-6.x use native consoles | Design decision | no identity UI in repo |
| Tests | Not implemented | no `tests/**` referencing openid/keycloak |
