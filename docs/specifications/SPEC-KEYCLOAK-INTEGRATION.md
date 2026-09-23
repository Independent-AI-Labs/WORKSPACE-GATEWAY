# SPEC-KEYCLOAK-INTEGRATION: Inbound Identity and Authorization Implementation

**Date:** 2026-09-23
**Status:** Draft
**Type:** Specification
**Requirements:** [REQ-KEYCLOAK-INTEGRATION](../requirements/REQ-KEYCLOAK-INTEGRATION.md)

> Intended configuration for consuming the DATAOPS Keycloak realm `workspace`
> for inbound identity: native `openid-connect` (bearer-only) and
> `authz-keycloak`, declarative claim mapping, and virtual-key identity binding.
> Configuration-only, using built-in plugins  -  no custom identity code. Nothing
> here is deployed yet; see the Implementation Status section.

---

**Cross-references:**
- [REQ-KEYCLOAK-INTEGRATION](../requirements/REQ-KEYCLOAK-INTEGRATION.md): requirements contract
- [AUTH-MODEL](../architecture/AUTH-MODEL.md): credential model
- [REQ-GATEWAY-GOVERNANCE](../requirements/REQ-GATEWAY-GOVERNANCE.md) / [SPEC-GATEWAY-GOVERNANCE](SPEC-GATEWAY-GOVERNANCE.md): control surface
- [SPEC-SECURITY-HARDENING](SPEC-SECURITY-HARDENING.md): `dataops_default` dual-homing, trust boundaries
- [SPEC-ENTERPRISE-AUTH](SPEC-ENTERPRISE-AUTH.md): retired predecessor (its OIDC half is absorbed here)
- [`conf/apisix.yaml`](../../conf/apisix.yaml), [`conf/config.yaml`](../../conf/config.yaml): deployed routes / plugin registration

---

## 1. Overview

The gateway joins two network planes: its own hardened stack and the external
`dataops_default` network where `workspace-keycloak` lives. This spec attaches
native auth plugins to gateway surfaces so that:

1. operators and API callers authenticate as Keycloak principals, and
2. authorization is decided by Keycloak roles/permissions  - 
while the existing virtual-key data path is preserved unchanged.

```
Browser / operator / service
  |  Authorization: Bearer <Keycloak JWT>       (control surface)
  v
APISIX route (governance / pilot)
  |-- openid-connect (bearer_only, native)  --> realm "workspace" (DATAOPS)
  |      claims_to_header: sub->X-Gateway-User-Id,
  |                        azp->X-Gateway-Client-Id,
  |                        groups->X-Gateway-Tenant-Id
  |-- authz-keycloak (native)               --> Keycloak Authorization Services
  v
Handler / upstream

Data plane (unchanged):
  Authorization: Bearer vgw-...  -> key-resolver (OpenBao) -> upstream credential
```

## 2. Architectural Principles

### 2.1 Native plugins only
Inbound OIDC is `openid-connect`; fine-grained authorization is
`authz-keycloak`. Both are present in APISIX 3.18.0. No custom JWT parsing,
signature verification, or JWKS fetching is written.

### 2.2 Two credential classes, one identity
OIDC JWT (humans/services) and hashed `vgw-*` virtual keys (long-lived/agents)
both resolve to a Keycloak identity. See [AUTH-MODEL](../architecture/AUTH-MODEL.md).

### 2.3 Fail closed
Missing, expired, invalid, or unverifiable tokens deny the request. Cold-start
JWKS failure is 401, never a passthrough.

### 2.4 Declarative mapping
Claim -> header mapping is route config (`claims_to_header`), not Lua.

## 3. `openid-connect` Configuration (bearer-only)

```yaml
plugins:
  openid-connect:
    client_id: "llm-gateway"                 # requested from DATAOPS REQ-IAM FR-15
    client_secret: "{{vault:secret/oidc/llm_gateway_client_secret}}"
    discovery: "http://keycloak:8080/realms/workspace/.well-known/openid-configuration"
    scope: "openid profile email"
    bearer_only: true
    realm: "workspace"
    access_token_in_authorization_header: false
    claims_to_header:
      - { claim: "sub",  header: "X-Gateway-User-Id" }
      - { claim: "azp",  header: "X-Gateway-Client-Id" }
      - { claim: "groups", header: "X-Gateway-Tenant-Id" }
```

| Property | Value |
|----------|-------|
| Mode | bearer-only resource server |
| Issuer | `http://keycloak:8080/realms/workspace` (in-stack); host view uses `:8082` |
| Backing library | `lua-resty-openidc` (JWKS cached in shared memory) |
| Multi-issuer | one instance per route per issuer; never issuer sniffing |

Failure modes (all fail closed):

| Failure | Behavior |
|---------|----------|
| No `Authorization: Bearer` | 401 `WWW-Authenticate: Bearer realm="workspace"` |
| Expired / invalid token | 401 `error="invalid_token"` |
| JWKS unreachable (cold start) | 401 `error="key_material_unavailable"` |
| Wrong audience / scope | 403 `error="insufficient_scope"` |

## 4. `authz-keycloak` Configuration (control surface)

Apply to governance/key-lifecycle/telemetry-read routes only:

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

| Property | Value |
|----------|-------|
| Mode | ENFORCING (deny by default) |
| Permission vocabulary | Aligned with WORKSPACE-PORTAL `resource:action` registry where possible |
| Decision input | Keycloak roles/permissions from the validated JWT |

## 5. Virtual-Key Identity Binding

Extend the OpenBao key record ([KEY-MANAGEMENT](../architecture/KEY-MANAGEMENT.md))
with identity attributes resolved from Keycloak at issuance time:

```json
{
  "data": {
    "virtual_key": "vgw-<hex>",
    "identity_sub": "<keycloak sub>",
    "identity_azp": "llm-gateway",
    "organization": "<org claim or group>",
    "tenant_id": "default",
    "user_id": "agent",
    "active": true
  }
}
```

`key-resolver` sets `X-Gateway-Key-Id`/`X-Gateway-Tenant-Id`/`X-Gateway-User-Id`
as today; the additional identity fields enable telemetry attribution without a
second identity store. Hash-at-rest and revocation stay on the existing
`issue-key`/`revoke-key` path.

## 6. OpenBao JWT Authentication (operators)

Target-state: an OIDC auth method on `gw-openbao` bound to the gateway client:

```bash
bao write auth/oidc/config \
  oidc_discovery_url="http://keycloak:8080/realms/workspace" \
  default_role="operator"
bao write auth/oidc/role/operator \
  bound_audiences="llm-gateway" \
  allowed_redirect_uris="http://localhost:8250/oidc/callback" \
  user_claim="sub" \
  policies="gateway-operator"
```

The data plane keeps the service `OPENBAO_TOKEN`; this method is for humans.
Convergence onto DATAOPS `workspace-openbao` is a separate target-state
(REQ FR-5.1).

## 7. Provisioning Flow (external dependency)

```
Gateway repo                         WORKSPACE-DATAOPS
-----------                          -----------------
request client "llm-gateway"  ---->  res/ansible/compose.yml provisions
                                     realm workspace + OIDC client
                                     (REQ-IAM FR-15, idempotent)
accept KEYCLOAK_CLIENT_ID     <----  prints client id/secret/issuer
KEYCLOAK_CLIENT_SECRET
```
No realm JSON, no Keycloak container, no published port in this repository.

## 8. Edge Cases & Decisions

- **Cold-start JWKS failure:** 401 (fail closed).
- **Keycloak outage:** routes that opted into OIDC fail closed; routes on
  virtual keys are unaffected (NFR-1.4).
- **Boundary:** custom `provider-oauth` stays outbound-only; inbound is
  exclusively `openid-connect`.
- **Config target:** examples apply via the etcd-backed Admin API/ADC used by
  this repo (`role: traditional`), not a standalone `apisix.yaml`.

## 9. File Map

| File | Purpose | Key Changes |
|------|---------|-------------|
| `conf/apisix.yaml` / Admin API (planned) | attach `openid-connect`/`authz-keycloak` to governance + pilot routes | add plugin blocks when adopted |
| `conf/config.yaml` (planned) | register native plugins if not default-enabled | add to plugin list |
| `res/scripts/issue-key.sh` (planned) | record Keycloak identity on virtual-key records | add identity lookup at issuance |
| `docs/architecture/AUTH-MODEL.md` | credential model | new |
| `.env.example` (planned) | `KEYCLOAK_*` client variables | add names, no secrets |

## 10. Implementation Status

| Component | Status | Evidence |
|-----------|--------|----------|
| `openid-connect` route config | Not implemented | no `openid-connect` in `conf/` |
| `authz-keycloak` config | Not implemented | no `authz-keycloak` in `conf/` |
| Claim-to-header mapping | Not implemented | no `claims_to_header` in `conf/` |
| Virtual-key identity binding | Not implemented | no `identity_sub`/`identity_azp` in key schema |
| OpenBao OIDC auth method | Not implemented | service token only |
| DATAOPS `llm-gateway` client | Not requested | no client; no realm JSON in repo |
| Tests | Not implemented | no `tests/**` referencing keycloak/openid |
