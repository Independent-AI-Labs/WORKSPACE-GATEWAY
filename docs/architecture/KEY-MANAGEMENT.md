# Key Management (OpenBao)

Virtual keys (`vgw-*`) for federated route; direct passthrough on
`/opencode/*`. Decision flow diagram:
[`README.md` Key Management](../../README.md#key-management).

## Architecture

```mermaid
graph TB
    subgraph bao [OpenBao file-storage]
        KV["KV v2 secret/data/gateway/keys/"]
    end
    subgraph keys [Key types]
        VK["Virtual vgw-*"]
        DK["Direct sk-* passthrough"]
    end
    subgraph scripts [Scripts]
        ISSUE[issue-key.sh]
        LIST[list-keys.sh]
        REVOKE[revoke-key.sh]
    end
    ISSUE --> KV
    LIST --> KV
    REVOKE --> KV
    VK --> KV
```

## Virtual key lifecycle

1. **Issued** via `make issue-key` -> OpenBao `active: true`
2. **Cached** in `key_cache` shared dict (5s dev TTL in route config)
3. **Revoked** via `make revoke-key` -> `active: false`, record preserved

## KV record schema

Path: `secret/data/gateway/keys/<virtual_key>`

```json
{
  "data": {
    "virtual_key": "vgw-<hex>",
    "upstream_key": "",
    "tenant_id": "default",
    "user_id": "agent",
    "active": true,
    "created_at": "2026-01-01T00:00:00Z",
    "revoked_at": null
  }
}
```

Empty `upstream_key` -> resolver uses `OPENCODE_API_KEY` env.
Non-empty `upstream_pool` -> resolver selects from the named upstream key
pool (see below), taking precedence over both.

## Upstream key pools (auto-rotation)

Named pools of upstream API keys with automatic rotation on upstream
quota/rate-limit responses. Multiple virtual keys can share one pool.

Path: `secret/data/gateway/upstream-pools/<pool_name>`

```json
{
  "data": {
    "keys": [
      {"id": "k1", "key": "sk-...", "active": true},
      {"id": "k2", "key": "sk-...", "active": true}
    ],
    "cooldown_on": [429],
    "disable_on": [402, 403],
    "cooldown_s": 3600,
    "epoch": 1784378000
  }
}
```

Rotation semantics (`key-resolver.lua`, sticky selection):

- First `active` key without an in-memory marker is used until exhausted.
- Upstream status in `cooldown_on` (default 429): key parked in
  `pool_state` shared dict for `cooldown_s`; subsequent requests use the
  next key. The upstream error response propagates to the client unchanged
  (retry-and-succeed semantics) with an added
  `X-Gateway-Upstream-Rotated: cooldown:<key_id>` header.
- Upstream status in `disable_on` (default 402, 403): key hard-disabled,
  marked in `pool_state` and written through to OpenBao (`active: false`)
  via timer. Header: `X-Gateway-Upstream-Rotated: disabled:<key_id>`.
- All keys unavailable: `503 {"error": "... pool exhausted ... retry later"}`.
- `epoch` is bumped on every management write and namespaces the in-memory
  markers, so `reset` immediately un-shadows previously disabled keys.

Management: `res/scripts/pool-key.sh`
(`create|add|remove|list|enable|disable|reset`), e.g.
`bash res/scripts/pool-key.sh create kimi && bash res/scripts/pool-key.sh add kimi k1 sk-...`.
Attach a pool to a virtual key with `issue-key.sh --pool <name>`.
Disabled keys are re-enabled with `pool-key.sh enable <pool> <key_id>` or
`reset <pool>`.

## Scripts

| Script | Make target |
|--------|-------------|
| `res/scripts/issue-key.sh` | `make issue-key` |
| `res/scripts/list-keys.sh` | `make list-keys` |
| `res/scripts/revoke-key.sh` | `make revoke-key KEY_ID=vgw-xxx` |
| `res/scripts/pool-key.sh` | `make pool-key ARGS='list'` |

## Entrypoint

`res/docker/openbao-entrypoint.sh` (production file-storage, `openbao-data`
volume): auto-init, auto-unseal, fixed service token matching `OPENBAO_TOKEN`,
provisions `vgw-gateway-key` on first start. Idempotent on restart.

Image: `res/docker/Dockerfile.openbao`, config: `conf/openbao.hcl`.