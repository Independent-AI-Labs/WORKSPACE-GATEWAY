# RUNBOOK-KEYS: Gateway Virtual Key Lifecycle

**Date:** 2026-07-17
**Status:** Active
**Type:** Runbook

---

## Purpose

Issue, list, and revoke virtual gateway keys (`vgw-*`) used on the federated
routes. Keys are stored in OpenBao KV v2 at `secret/data/gateway/keys/<key_id>`
and resolved at request time by the `key-resolver` plugin (cached in the
`key_cache` shared dict). Architecture and KV record schema:
[KEY-MANAGEMENT](../architecture/KEY-MANAGEMENT.md).

## Prerequisites

- Stack running, OpenBao reachable (default `http://localhost:8201`).
- `OPENBAO_TOKEN` set in repo-root `.env` (all scripts source `.env`
  automatically; `ENV_FILE` env var overrides the path).
- `curl` and `jq` installed.
- Environment variables honored by all three scripts:
  - `OPENBAO_ADDR` (default `http://localhost:8201`)
  - `OPENBAO_TOKEN` (falls back to a built-in dev token if unset)
  - `ENV_FILE` (default `<repo>/.env`)

## Procedures

### 1. Issue a key

Script: [`res/scripts/issue-key.sh`](../../res/scripts/issue-key.sh).
Make target: `make issue-key`.

```bash
bash res/scripts/issue-key.sh \
  --key-id vgw-alice-01 \
  --tenant acme \
  --user alice \
  --rate-limit-rpm 100 \
  --token-budget 0
```

| Flag | Default | Meaning |
|------|---------|---------|
| `--key-id ID` | `vgw-<random 16-byte hex>` | Key identifier (the Bearer token clients send) |
| `--tenant ID` | `default` | Tenant ID |
| `--user ID` | `agent` | User ID |
| `--upstream-key KEY` | empty | Upstream API key; empty = gateway uses `OPENCODE_API_KEY` env |
| `--rate-limit-rpm N` | `100` | Per-key requests per window |
| `--rate-limit-window S` | `60` | RPM window seconds |
| `--token-budget N` | `0` (unlimited) | Token budget per window |
| `--cost-budget N` | `0` (unlimited) | Cost budget in cents per window |
| `--budget-window S` | `86400` | Budget window seconds |
| `--budget-type TYPE` | `tokens` | `tokens` or `cost` |

The script POSTs the record to
`$OPENBAO_ADDR/v1/secret/data/gateway/keys/<key_id>` with `active: true` and a
`created_at` UTC timestamp.

### 2. List keys

Script: [`res/scripts/list-keys.sh`](../../res/scripts/list-keys.sh).
Make target: `make list-keys`.

```bash
bash res/scripts/list-keys.sh
```

Prints a table of `KEY_ID / TENANT / USER / ACTIVE / CREATED` by LISTing
`secret/metadata/gateway/keys/` and reading each record. Exits 0 with
"No keys found" when OpenBao is unreachable or the list is empty.

### 3. Revoke a key

Script: [`res/scripts/revoke-key.sh`](../../res/scripts/revoke-key.sh).
Make target: `make revoke-key KEY_ID=vgw-xxx`.

```bash
bash res/scripts/revoke-key.sh vgw-alice-01
```

Revocation is soft: the script reads the record, sets `active: false`, adds a
`revoked_at` ISO-8601 timestamp, and writes it back. The record is preserved
for audit; the key is never deleted. Fails (exit 1) if the key does not exist
or OpenBao is unreachable.

### 4. Inspect a key record directly

```bash
curl -sS -H "X-Vault-Token: $OPENBAO_TOKEN" \
  http://localhost:8201/v1/secret/data/gateway/keys/vgw-alice-01 | jq .data.data
```

## Verification

1. Issue a test key, then `bash res/scripts/list-keys.sh` shows it with
   `ACTIVE=true`.
2. Send a request on a federated route with
   `Authorization: Bearer vgw-<id>`; expect a non-401 response.
3. Revoke it; repeat the request; expect 401 once the `key_cache` TTL
   (route-configured, 5s in dev) expires.
4. The record still exists in OpenBao with `active: false` and `revoked_at`
   set.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `ERROR: OpenBao write failed` | OpenBao down or sealed | Check stack health; see [RUNBOOK-DEPLOYMENT](RUNBOOK-DEPLOYMENT.md) |
| `curl exit 22` / 403 on any script | Wrong `OPENBAO_TOKEN` | Re-export from `.env`; token must match `conf/openbao.hcl` provisioning |
| list-keys prints "No keys found" but keys exist | Wrong `OPENBAO_ADDR` (must be host port 8201) | `export OPENBAO_ADDR=http://localhost:8201` |
| Revoked key still works | `key_cache` shared dict TTL not yet expired | Wait for TTL or `restart apisix` |
| `unknown option` from issue-key.sh | Unsupported flag | Only the flags in the table above are accepted |
| revoke-key: `key not found` | Key ID typo or never issued | Verify with list-keys |
