# SPEC-PROVIDER-ALIBABA-TOKEN-PLAN: Alibaba Cloud Token Plan Implementation

**Date:** 2026-09-20
**Status:** Draft
**Type:** Specification
**Requirements:** [REQ-PROVIDER-ALIBABA-TOKEN-PLAN](../requirements/REQ-PROVIDER-ALIBABA-TOKEN-PLAN.md)
**Research:** [RES-PROVIDER-ALIBABA-TOKEN-PLAN](../research/RES-PROVIDER-ALIBABA-TOKEN-PLAN.md)

> Implements the Alibaba Cloud Model Studio Token Plan provider as pure
> configuration: 2 own-key passthrough relay routes to the two Token Plan
> endpoint hosts (International/Singapore and China/Beijing), plus 2 OpenCode
> provider definitions. No custom plugin code. Architecture context:
> [architecture/README.md](../architecture/README.md).

---

**Cross-references:**
- [REQ-PROVIDER-ALIBABA-TOKEN-PLAN](../requirements/REQ-PROVIDER-ALIBABA-TOKEN-PLAN.md): requirements
- [RES-PROVIDER-ALIBABA-TOKEN-PLAN](../research/RES-PROVIDER-ALIBABA-TOKEN-PLAN.md): endpoint catalog and verification
- [SPEC-PROVIDER-ZAI](SPEC-PROVIDER-ZAI.md): own-key passthrough analog
- [SPEC-PROVIDER-ANTHROPIC](SPEC-PROVIDER-ANTHROPIC.md): bare-relay route and identity-encoding baseline
- [`conf/apisix.yaml`](../../conf/apisix.yaml) / [`conf/apisix.yaml.j2`](../../conf/apisix.yaml.j2): routes
- [`conf/providers/`](../../conf/providers): provider definitions

---

## 1. Overview

```mermaid
graph TB
    C[Client] -->|Authorization: Bearer sk-sp-key| R[/token-plan/* or /token-plan-cn/* passthrough]
    R --> PRW[proxy-rewrite: strip prefix, accept-encoding identity]
    PRW --> INTL[token-plan.ap-southeast-1.maas.aliyuncs.com]
    PRW --> CN[token-plan.cn-beijing.maas.aliyuncs.com]
```

No new plugins, containers, or storage. The Token Plan has no OAuth or
device grant (RES section 4), so own-key passthrough is the only and
sufficient mode. This mirrors the `relay-anthropic` bare passthrough (no
auth plugin, path-only rewrite, identity encoding) and the Z.ai own-key
routes.

## 2. Upstream Contract (verified 2026-09-20)

| Item | Value |
|------|-------|
| International host | `token-plan.ap-southeast-1.maas.aliyuncs.com:443` (HTTPS) |
| China host | `token-plan.cn-beijing.maas.aliyuncs.com:443` (HTTPS) |
| Anthropic base | `/apps/anthropic` (Claude Code) and `/apps/anthropic/v1` (OpenCode) |
| OpenAI base | `/compatible-mode/v1` |
| Auth | `Authorization: Bearer <sk-sp-… plan key>` (client-held, forwarded as-is; `x-api-key` also passes through) |
| Models (text/coding) | `qwen3.8-max`, `qwen3.8-flash`, `qwen3.7-max`, `qwen3.7-plus`, `qwen3.6-flash`, `glm-5.3`, `glm-5.2`, `deepseek-v4-pro`, `deepseek-v4.1-flash`, `deepseek-v4-flash-0731` |
| Billing | Monthly Credits, per-token (not per-request) |
| Out of scope | Coding Plan (`coding*.dashscope.aliyuncs.com`), PAYG/trial/workspace `sk-` domains, native DashScope `/api/v1`, console `o1_` key form |

Constraint (RES sections 1, 5): Token Plan and Coding Plan share the
`sk-sp-` prefix and their base URLs are mutually exclusive  -  a Token Plan
key on a Coding Plan host returns 401 (`invalid access token or token
expired`). The International console's subscription page prints the
token-plan host as the plan's exclusive base URL; that URL is authoritative
over documentation tables that differ.

## 3. Routes

Both routes upstream over HTTPS with `pass_host: node`, rewrite only the
route prefix, and force `accept-encoding: identity`:

| Route id | URI | Upstream node | Rewrite | Auth |
|----------|-----|---------------|---------|------|
| `relay-alibaba-token-plan` | `/token-plan/*` | `token-plan.ap-southeast-1.maas.aliyuncs.com:443` | `^/token-plan/(.*)` -> `/$1` | none (passthrough) |
| `relay-alibaba-token-plan-cn` | `/token-plan-cn/*` | `token-plan.cn-beijing.maas.aliyuncs.com:443` | `^/token-plan-cn/(.*)` -> `/$1` | none (passthrough) |

Common route plugins: `proxy-rewrite` (with the identity header set),
`key-meta`, `limit-count` (100/60s per `http_x_key_hash`), `prometheus`,
`request-id`, `http-logger`, `proxy-buffering` (disabled), `redact`,
`sse-usage`.

Reference block (International; the China block differs only in `id`,
`uri`, `regex_uri`, and upstream node):

```yaml
  - id: relay-alibaba-token-plan
    # Bare passthrough (REQ-PROVIDER-ALIBABA-TOKEN-PLAN FR-1): no auth
    # plugin. The client's own sk-sp- plan key and both protocol paths
    # (/compatible-mode/v1, /apps/anthropic) pass through verbatim; only
    # the route prefix is stripped.
    uri: /token-plan/*
    upstream:
      type: roundrobin
      scheme: https
      pass_host: node
      nodes:
        "token-plan.ap-southeast-1.maas.aliyuncs.com:443": 1
    plugins:
      proxy-rewrite:
        regex_uri: ["^/token-plan/(.*)", "/$1"]
        headers:
          set:
            accept-encoding: "identity"
      key-meta: {}
      limit-count:
        count: 100
        time_window: 60
        rejected_code: 429
        key_type: var
        key: http_x_key_hash
        policy: local
      prometheus: { prefer_name: true }
      request-id: { header_name: X-Request-Id, include_in_response: true }
      http-logger:
        uri: "http://vector:8080/ingest"
        method: POST
        content_type: "application/json"
        batch_max_size: 1
        include_req_body: true
        include_resp_body: true
        max_req_body_bytes: 262144
        max_resp_body_bytes: 1048576
      proxy-buffering: { disable: true }
      redact: { patterns_file: "/etc/apisix/redact-patterns.json" }
      sse-usage:
        clickhouse_addr: "http://clickhouse:8123"
        clickhouse_user: "apisix_rw"
        clickhouse_password_env: "CH_APISIX_PASSWORD"
```

Identical blocks are committed in `conf/apisix.yaml` and
`conf/apisix.yaml.j2` (the nodes are untemplated); the render drift test
(`tests/config/test_apisix_yaml_render.sh`) keeps them in sync.

## 4. OpenCode Providers

`conf/providers/workspace-gw-alibaba-token-plan-passthrough.yaml` (shown) and
`workspace-gw-alibaba-token-plan-cn-passthrough.yaml` (China variant):

```yaml
---
id: workspace-gw-alibaba-token-plan-passthrough
name: "Workspace GW (Alibaba Cloud Token Plan Passthrough)"
provider:
  id: alibaba-token-plan
  label: Alibaba Cloud Token Plan
route: "/token-plan"
npm: "@anthropic-ai/sdk"
auth:
  type: passthrough
options:
  headers:
    X-Tenant-ID: default
    X-User-ID: agent
context_limit_ceiling: 256000
model_source:
  type: models_dev_provider
  provider: qwen
pricing:
  source:
    type: models_dev
    provider: qwen
  missing_policy: unknown
```

The China variant sets `provider.id: alibaba-token-plan-cn`,
`label: Alibaba Cloud Token Plan (China)`, `route: /token-plan-cn`,
`id: workspace-gw-alibaba-token-plan-cn-passthrough`.

Notes:
- `auth.type: passthrough` is the existing provider-sync contract value
  (`provider_sync_contract.lua`); no credentials are written to client auth
  stores and the opencode login tool skips auth for it
  (`opencode-provider-login.sh`). Clients supply their own `sk-sp-` key.
- `npm` is `@anthropic-ai/sdk` because the primary coding-agent path is the
  Anthropic-compatible `/apps/anthropic` protocol; the OpenAI-compatible
  `/compatible-mode/v1` path is reachable through the same route for
  OpenAI-SDK clients.
- `model_source` follows the repo's models.dev pattern (all existing
  providers use `models_dev_provider`); the live endpoint catalog is recorded
  in RES section 3. See OQ in REQ section 6 on models.dev id coverage.

## 5. Telemetry

`plugins/custom/cost_calc.lua` `ROUTE_PROVIDERS` (the single route→provider
map, required by `sse-usage.lua`) gains:

```lua
["relay-alibaba-token-plan"] = "workspace-gw-alibaba-token-plan-passthrough",
["relay-alibaba-token-plan-cn"] = "workspace-gw-alibaba-token-plan-cn-passthrough",
```

Anthropic-compatible streams carry the Anthropic usage shape
(`message_start.message.usage`, input/output events) handled by
`sse_usage_lib.lua`; OpenAI-compatible streams carry the standard `usage`
object. Both were observed on the live endpoint (RES section 6), so no
parser changes are expected.

## 6. Error & Failure Model

The gateway adds no auth errors on these routes; upstream responses (401
invalid/expired key or key/endpoint mismatch, 429 quota, 404 wrong path)
pass through verbatim. Gateway-side failures are the common relay stack only
(rate limit 429, telemetry sink errors).

## 7. Edge Cases & Decisions

- **Only two Token Plan hosts wired.** International (Singapore) and China
  (Beijing) are the Token Plan regions; other Model Studio regions have no
  Token Plan endpoint and their PAYG hosts reject plan keys (RES sections 1,
  5). Adding one later is a one-block clone.
- **Both protocols on one route each.** The relay is path-transparent, so
  Claude Code (`/apps/anthropic`), OpenCode (`/apps/anthropic/v1`), and
  OpenAI-SDK clients (`/compatible-mode/v1`) all work through the same route
  without extra path variants.
- **Identity encoding** is forced upstream for the same reason as the
  Anthropic route: compressed SSE hides usage from telemetry.
- **Console URL is authoritative.** The subscription page's "PLAN EXCLUSIVE
  BASE URL" is the token-plan host; documentation tables that label the same
  subscription Coding Plan are contradicted by the 200-vs-401 test in RES
  section 5, and the console wins.
- **No `o1_` decoding.** The gateway never sees the console-obfuscated key
  form; clients present the decoded `sk-sp-` key (RES section 4).
- **Naming collision check:** `/token-plan` and `/token-plan-cn` are unused
  by existing routes.

## 8. File Map

| File | Purpose | Key Changes |
|------|---------|-------------|
| `conf/apisix.yaml` | 2 `relay-alibaba-token-plan*` routes | passthrough, identity encoding |
| `conf/apisix.yaml.j2` | identical route blocks | drift-kept in sync |
| `conf/providers/workspace-gw-alibaba-token-plan-passthrough.yaml` | Intl OpenCode provider | passthrough, models.dev qwen |
| `conf/providers/workspace-gw-alibaba-token-plan-cn-passthrough.yaml` | China OpenCode provider | passthrough, models.dev qwen |
| `plugins/custom/cost_calc.lua` | `ROUTE_PROVIDERS` mapping (single source) | 2 new entries |
| `tests/config/test_alibaba_token_plan_routes.sh` | route assertions | new, sourced by `test_apisix_yaml.sh` |
| `tests/config/test_apisix_yaml.sh` | route count | 16 -> 18 |
| `res/scripts/seed-routes.sh` | live route seeding | redirect exec stdin to `/dev/null` so the PUT loop stops consuming its own route list (pre-existing bug exposed by adding >1 route) |

## 9. Implementation Status

| Component | Status | Evidence |
|-----------|--------|----------|
| 2 relay routes (.yaml + .j2) | Implemented | conf/apisix.yaml, conf/apisix.yaml.j2; seeded live (18/18 routes) |
| 2 provider YAMLs | Implemented | conf/providers/workspace-gw-alibaba-token-plan{-cn,}-passthrough.yaml; 28 enriched models each |
| Route-provider map | Implemented | plugins/custom/cost_calc.lua `ROUTE_PROVIDERS` (required by sse-usage.lua); activated via a clean `apisix reload` - `provider_id` resolves to `workspace-gw-alibaba-token-plan-passthrough` |
| Config tests | Implemented | tests/config/test_alibaba_token_plan_routes.sh + `test_apisix_yaml.sh` (18) + `test_apisix_yaml_render.sh` (11/11) |
| E2E live passthrough | Verified | OpenAI + Anthropic paths 200, SSE stream 200, CN route forwards (upstream 401 w/o CN key), usage_log records qwen3.8-max |
