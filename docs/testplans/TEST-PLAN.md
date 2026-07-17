# TEST-PLAN: WORKSPACE-GATEWAY

**Date:** 2026-07-17
**Status:** Active
**Type:** Test Plan

---

## 1. Overview

End-to-end testing and verification plan for WORKSPACE-GATEWAY: Apache APISIX
3.17.0 in etcd/traditional mode acting as an LLM relay (OpenCode Go, Moonshot
Kimi, local llamafile) with PII redaction, virtual-key resolution, rate
limiting, telemetry logging, and billing-grade token accounting.

Open/unremediated issues are tracked in
[OPEN-ISSUES](../architecture/OPEN-ISSUES.md); they are intentionally not
duplicated here.

## 2. Test Architecture: Extract-Testable-Core

Custom plugins split pure logic (requireable Lua modules: `redact_lib.lua`,
`sse_usage_lib.lua`, `cost_calc.lua`) from Nginx-coupled adapters
(`redact.lua`, `sse-usage.lua`, ...). This enables three layers:

| Layer | What | Tool | Needs Nginx? |
|-------|------|------|--------------|
| Unit | Pure logic functions | `resty` CLI in Podman | No |
| Integration | Plugin lifecycle, black-box | curl vs running stack | Yes |
| E2E | Full request to live upstream | curl vs running stack + upstream key | Yes |

## 3. Stage Layout

Seven stages, run in order by [`tests/run_all.sh`](../../tests/run_all.sh).
Each stage is independently runnable and yields a pass/fail exit code.

| Stage | Name | Runner | Dependencies |
|-------|------|--------|--------------|
| 1 | Lua Unit Tests | `tests/lua/run.sh` | APISIX image (resty CLI) |
| 2 | Script Tests | `tests/scripts/run.sh` | Python (mock provider server) |
| 3 | Config Validation | `tests/config/run.sh` | jq + Python |
| 4 | Reconciler Tests | `tests/reconciler/test_reconciler.sh` | None |
| 5 | Integration Tests | `tests/integration/run.sh` | podman-compose stack |
| 6 | CI Hook Verification | `tests/ci/test_hooks.sh` | git, CI repo |
| 7 | E2E Live API Tests | `tests/e2e/run.sh` | Running stack + `OPENCODE_API_KEY` |

`run_all.sh` behavior:

- Sources `.env`; detects an already-running stack (`podman ps | grep apisix`)
  and sets `EXTERNAL_STACK=1` so it will not tear it down.
- Stage 7 is **skipped** unless `OPENCODE_API_KEY` is set; when it runs, the
  stack is kept up between stages and torn down afterwards (unless external).
- Prints `Overall: N stages passed, M stages failed`; exits 1 on any failure.

Stages 1-4 run without network access. Stage 5 requires image pulls. Stage 7
requires outbound HTTPS and consumes upstream credits.

## 4. Prerequisites

### 4.1 Tools

Podman 5.6.2+, podman-compose, jq, Python 3.10+, curl, git.

### 4.2 Environment variables

| Variable | Required for | Source |
|----------|-------------|--------|
| `OPENCODE_API_KEY` | Stage 7 | `.env` |
| `OPENBAO_TOKEN` | Stage 5, 7 | `.env` |
| `GATEWAY_API_KEY` | Stage 5, 7 (virtual `vgw-*` key in OpenBao) | `.env` |
| `CONTEXT_LIMIT_PCT`, `CONTEXT_LIMIT_CEILING` | model sync tests | `.env` |

## 5. Test File Layout

```
tests/
  lua/         test_redact_lib.lua, test_sse_usage_lib.lua,
               test_kimi_jwt.lua, test_provider_sync.lua, run.sh
  scripts/     test_opencode_provider_login.sh, mock_provider_server.py, run.sh
  config/      test_apisix_yaml.sh, test_apisix_yaml_render.sh,
               test_config_yaml.sh, test_compose.sh, test_dockerfile.sh,
               test_patterns_json.sh, test_clickhouse_sql.sh,
               test_vector_toml.sh, test_migrations.sh,
               test_model_registry.sh, test_cost_calc.sh,
               test_grafana_provisioning.sh, test_dashboard_cost_usage.sh,
               test_dashboard_ops_health.sh, test_dashboard_cost_leaderboard.sh,
               dashboard_assert.sh, yaml_helpers.sh, run.sh
  reconciler/  test_reconciler.sh
  integration/ test_stack_up.sh, test_key_resolver.sh, test_route_relay.sh,
               test_prometheus.sh, test_grafana.sh, test_dashboard_queries.sh,
               test_grafana_ds_proxy.sh, test_grafana_panels.sh,
               grafana_panel_check.js, test_llamafile_e2e.sh,
               test_event_id_alignment.sh, test_data_flow.sh,
               test_cost_e2e.sh, test_reconciler_exec.sh,
               test_provider_sync_client.sh, lib_event_align.sh, run.sh
  ci/          test_hooks.sh
  e2e/         test_zen_chat.sh, test_zen_stream.sh, test_redact_e2e.sh,
               test_stream_redact.sh, test_invalid_model.sh, run.sh
  run_all.sh
```

## 6. Stage 1: Lua Unit Tests

Runs `resty` inside the APISIX image (`-I /plugins/custom` on the module path)
against the pure modules. Assert-based, non-zero exit on failure.

**redact_lib** (`test_redact_lib.lua`, 44 assertions):

- `luhn_valid`: valid Visa/Mastercard test numbers true; off-by-one and random
  numbers false; spaces/dashes tolerated; non-numeric false.
- `load_patterns`: normal load of `conf/redact-patterns.json` (6 regex entries,
  dictionary built); missing file and invalid JSON return `nil, error`.
- `redact_text`: email -> `[EMAIL_1]`, SSN -> `[SSN_1]`, Luhn-valid card ->
  `[CREDIT_CARD_1]` (invalid card left unchanged), `sk-`/`pk-`/`key-` strings
  -> `[API_KEY_1]`, phone -> `[PHONE_1]`, JWT -> `[JWT_1]`, dictionary entries
  -> `[DICTIONARY_1]`, multiple PII types in one string, empty input, IPv4
  redaction gated on `redact_ips` flag.
- `restore_with_key`: single/multiple token re-hydration; unknown token and
  empty text pass through unchanged.

**sse_usage_lib** (`test_sse_usage_lib.lua`, 45 assertions): SSE usage parsing
across complete, truncated, and chunked event streams; CJK-aware token
estimation.

**kimi_jwt / provider_sync** (`test_kimi_jwt.lua`, `test_provider_sync.lua`):
JWT claim decoding/expiry/token-hash helpers; provider-sync catalog/pricing
logic.

## 7. Stage 2: Script Tests

`test_opencode_provider_login.sh` exercises the client login script against
`mock_provider_server.py` (a local mock of `/gateway/providers*`): flag
validation, provider block merge into config, auth.json writing, error paths
(bad provider id, `--no-prompt` with api_key auth, invalid config).

## 8. Stage 3: Config Validation

Shell + jq + Python `yaml.safe_load` assertions over every config artifact.
Representative checks:

- **apisix.yaml** (`test_apisix_yaml.sh`, 70+): valid YAML; exactly 10 routes;
  per-route uri/upstream/plugin matrix for the relay-* and
  gateway-provider-sync routes; no `consumers` section.
  `test_apisix_yaml_render.sh` validates env substitution.
- **config.yaml** (`test_config_yaml.sh`, 30+): `role: traditional`,
  `config_provider: etcd`, etcd host `http://etcd:2379`; custom plugins
  registered (`key-resolver`, `key-meta`, `kimi-auth`, `provider-sync`,
  `sse-usage`, `redact`); shared dicts `redact_state`, `key_cache`,
  `gateway-cache`, `quota_counters`; `nginx_config.envs` includes
  `OPENCODE_API_KEY`, `OPENBAO_TOKEN`; prometheus export on `:9100`.
- **compose** (`test_compose.sh`): valid YAML; services apisix, clickhouse,
  vector, openbao, prometheus, grafana, etcd, migrate; mounts, ports, networks
  (`gateway`, `dataops`).
- **Dockerfile.apisix** (`test_dockerfile.sh`): base
  `apache/apisix:3.17.0-debian`; copies plugins, `conf/config.yaml`,
  `conf/redact-patterns.json`.
- **redact-patterns.json**: valid JSON; 6 regex + 2 dictionary entries;
  `luhn_check` on credit_card; `kind`/`pattern` fields present.
- **clickhouse-init.sql**: database `llm_gateway`; tables `request_log`,
  `billing_ledger`, `billing_discrepancies`; `Decimal64(6)` cost; 13-month TTL;
  low-cardinality ORDER BY keys.
- **vector.toml**: `http_server` source on `0.0.0.0:8080` path `/ingest`;
  clickhouse sink to `http://clickhouse:8123`, database `llm_gateway`,
  `skip_unknown_fields`; remap parses bodies and extracts token/header fields.
- **migrations** (`test_migrations.sh`): `conf/migrations/` files consistent
  with the schema documented in `docs/architecture/TELEMETRY-AND-SCHEMA.md`.
- **model_registry / cost_calc** (`test_model_registry.sh`,
  `test_cost_calc.sh`): registry codegen output and pricing lookup API
  (`get_pricing`/`compute_cost`/`resolve_cost`) in container LuaJIT.
- **Grafana** (`test_grafana_provisioning.sh`, `test_dashboard_*.sh`):
  datasources (Prometheus default proxy, ClickHouse on `clickhouse:8123`,
  `llm_gateway`), three dashboard JSONs valid with unique uids, panel
  types/counts, templating parity, `conf/prometheus.yml` scrape targets.

## 9. Stage 4: Reconciler Tests

`tests/reconciler/test_reconciler.sh` validates
[`res/scripts/reconciler.sh`](../../res/scripts/reconciler.sh): `bash -n`
syntax, `set -euo pipefail`, `CLICKHOUSE_HOST`/`CLICKHOUSE_PORT` defaults,
error handling on query failure, graceful empty-result handling, and presence
of the upstream-API TODO marker.

## 10. Stage 5: Integration Tests

Black-box against the full podman-compose stack; torn down via trap unless
`EXTERNAL_STACK=1`. Cases:

| Test | Asserts |
|------|---------|
| `test_stack_up.sh` | Image build, all services running, ports respond, ClickHouse tables exist |
| `test_key_resolver.sh` | Virtual key resolved on federated route (non-401) |
| `test_route_relay.sh` | Relay route reaches upstream (non-404) |
| `test_prometheus.sh` | Metrics endpoint scrapable |
| `test_grafana.sh`, `test_grafana_ds_proxy.sh`, `test_grafana_panels.sh` | Grafana up, datasource proxy works, panels render (Playwright via `grafana_panel_check.js`) |
| `test_dashboard_queries.sh` | Dashboard ClickHouse queries return sane results |
| `test_llamafile_e2e.sh` | Local llamafile round-trip (skips if unreachable) |
| `test_event_id_alignment.sh` | `request_id`/`event_id` alignment across request_log/usage_log (live) |
| `test_data_flow.sh` | APISIX -> Vector -> ClickHouse row lands (live) |
| `test_cost_e2e.sh` | Cost computation end-to-end via llamafile (live) |
| `test_reconciler_exec.sh` | Reconciler executes against the stack |
| `test_provider_sync_client.sh` | `/gateway/providers*` endpoints serve catalog/opencode blocks |

## 11. Stage 6: CI Hook Verification

`tests/ci/test_hooks.sh`: `.git/hooks/pre-commit` and `pre-push` exist and are
executable; `.pre-commit-config.yaml` defines `check-banned-words`,
`block-sensitive-files`, `gitleaks`, `ci-check-push`, `check-dead-code`;
`banned_words.yaml` exists. No test commits are created; hooks are exercised
implicitly on real commits.

## 12. Stage 7: E2E Live API Tests

Gated on `OPENCODE_API_KEY` (skipped otherwise). Real chat requests through the
gateway to the live upstream; consumes credits.

| Test | Expected |
|------|----------|
| `test_zen_chat.sh` | Non-streaming chat: 200, non-empty `choices[0].message.content` |
| `test_zen_stream.sh` | Streaming: 200, `Content-Type: text/event-stream`, SSE events |
| `test_redact_e2e.sh` | PII prompt yields `X-Redact-Active: 1` response header |
| `test_stream_redact.sh` | SSE redaction + token restoration on the stream path |
| `test_invalid_model.sh` | Invalid model handled with a clean error |

Redaction is verified black-box (response header + PII not echoed); upstream
request-body inspection is covered by Stage 1 unit tests.

## 13. Success Criteria

- `bash tests/run_all.sh` exits 0 with all applicable stages passing
  (Stage 7 reported as SKIP without `OPENCODE_API_KEY` is not a failure).
- No stage mutates git history or leaves a self-started stack running.

## 14. Open Issues

Known coverage gaps (concurrency races, Vector/sse-usage failure injection,
historical data misalignment) are tracked in
[OPEN-ISSUES](../architecture/OPEN-ISSUES.md).
