# Test Plan: WORKSPACE-GATEWAY

**Project:** WORKSPACE-GATEWAY
**Platform:** Apache APISIX 3.17.0, OpenCode Go
**Date:** 2026-07-06

---

## 1. Overview

This document defines the end-to-end testing and verification plan
for the WORKSPACE-GATEWAY project. The gateway uses Apache APISIX
3.17.0 as a relay to OpenCode Go, with PII redaction, rate
limiting, telemetry logging, and billing-grade token accounting.

- Upstream: OpenCode Go (`https://opencode.ai/zen/go/v1`)
- Gateway port: 9080 (HTTP), 9443 (HTTPS)
- Key models: `minimax-m3`, `mimo-v2.5`,
  `glm-5`, `deepseek-v4-pro`,
  `kimi-k2.6`

---

## 2. Architecture: Extract-Testable-Core

The `redact` plugin has two categories of code:

1. **Pure logic** - Luhn validation, pattern loading, text
   redaction, token restoration. Depends only on `ngx.re.gsub`
   and `cjson.safe`, both available via the `resty` CLI.
2. **Nginx-coupled code** - request body reading, response header
   manipulation, response body filtering. Depends on `ngx.req`,
   `ngx.arg`, `ngx.header` - only available inside the Nginx
   request lifecycle.

Pure logic is extracted into `redact_lib.lua` as a requireable
module with exported (non-local) functions. The main `redact.lua`
becomes a thin adapter that wires the logic into APISIX lifecycle
methods.

This enables three test layers:

| Layer | What | Tool | Needs Nginx? |
|-------|------|------|--------------|
| Unit | Pure logic functions | `resty` CLI | No |
| Integration | Plugin lifecycle | curl vs running APISIX | Yes |
| E2E | Full request to OpenCode Go (gated) | curl vs running stack + OpenCode Go key | Yes |

---

## 3. Testing Strategy

Six stages, from fast unit tests to slow end-to-end tests. Each
stage is independently runnable and produces a pass/fail exit code.

| Stage | Scope | Speed | Runner | Dependencies |
|-------|-------|-------|--------|--------------|
| 1 | Lua unit tests (redact_lib.lua) | <5s | `resty` CLI in Podman | APISIX image |
| 2 | Config validation | <2s | Shell + jq + Python | None |
| 3 | Reconciler script | <1s | Shell | None |
| 4 | Podman stack integration | <60s | podman-compose | APISIX, ClickHouse, Vector, OpenBao, Prometheus, Grafana images |
| 5 | CI hook verification | <5s | Shell + git | CI repo |
| 6 | End-to-end OpenCode Go API | <30s | Shell + curl | Running stack + OpenCode Go key |

Stages 1 through 3 run without network access. Stage 4 requires
Podman image pulls. Stage 6 requires outbound HTTPS to
`opencode.ai`. Stages 4 (data-flow) and 6 are **live API tests**
gated behind `RUN_LIVE_API_TESTS=1`; they are skipped by default
(`make test`) and only run with `make test-live`.

---

## 4. Prerequisites

### 4.1 Tools

| Tool | Version | Purpose |
|------|---------|---------|
| Podman | 5.6.2+ | Container runtime for APISIX, ClickHouse, Vector |
| podman-compose | any | Stack orchestration |
| jq | any | JSON validation in config tests |
| Python | 3.10+ | YAML parsing in config tests |
| curl | any | HTTP requests in integration and E2E tests |
| git | any | CI hook verification |

### 4.2 Environment Variables

| Variable | Required For | Source |
|----------|-------------|--------|
| `OPENCODE_API_KEY` | Stage 6 | `.env` file |
| `OPENCODE_BASE_URL` | Stage 6 | `.env` file |
| `OPENBAO_TOKEN` | Stage 4, 6 | `.env` file |
| `CONTEXT_LIMIT_PCT` | sync-models | `.env` file |
| `CONTEXT_LIMIT_CEILING` | sync-models | `.env` file |
| `GATEWAY_API_KEY` | Stage 4, 6 | `.env` file |

`GATEWAY_API_KEY` is the virtual gateway key `vgw-gateway-key`
(provisioned in OpenBao, NOT a key-auth consumer key). The
`key-resolver` plugin resolves it against keys stored in OpenBao.

### 4.3 Files Under Test

| File | Stage |
|------|-------|
| `plugins/custom/redact_lib.lua` | 1 |
| `plugins/custom/sse_usage_lib.lua` | 1 |
| `plugins/custom/cost_calc.lua` | 2 (config test in container `luajit`) |
| `plugins/custom/redact.lua` | 4 (integration) |
| `plugins/custom/sse-usage.lua` | 4 (integration) |
| `plugins/custom/key-meta.lua` | 4 (integration) |
| `conf/apisix.yaml` | 2, 4, 6 |
| `conf/config.yaml` | 2 |
| `conf/redact-patterns.json` | 1, 2 |
| `conf/clickhouse-init.sql` | 2 |
| `conf/vector.toml` | 2 |
| `conf/openbao.hcl` | 2 |
| `conf/prometheus.yml` | 2 |
| `conf/grafana/dashboards/gateway-overview.json` | 2 |
| `res/docker/docker-compose.yml` | 2, 4, 6 |
| `res/docker/Dockerfile.apisix` | 2, 4 |
| `res/docker/Dockerfile.openbao` | 2, 4 |
| `res/docker/openbao-entrypoint.sh` | 2, 4 |
| `res/scripts/reconciler.sh` | 3 |
| `tests/config/test_grafana_provisioning.sh` | 2 |
| `tests/config/test_cost_calc.sh` | 2 |
| `tests/integration/test_grafana.sh` | 4 |
| `tests/integration/test_data_flow.sh` | 4 (live API) |
| `tests/integration/test_reconciler_exec.sh` | 4 |
| `tests/e2e/test_stream_redact.sh` | 6 (live API) |
| `tests/e2e/test_invalid_model.sh` | 6 (live API) |

---

## 5. Test File Layout

```
plugins/custom/
  redact_lib.lua               Pure logic (requireable module)
  sse_usage_lib.lua            SSE usage parsing (requireable module)
  cost_calc.lua                Cost computation module (lazy requires, testable in plain LuaJIT)
  redact.lua                   Thin adapter (APISIX lifecycle)
  sse-usage.lua                SSE usage + cost tracking plugin (APISIX lifecycle)
  key-meta.lua                 Key metadata + hashing plugin (APISIX lifecycle)
tests/
  lua/
    test_redact_lib.lua        Lua unit tests for redact_lib
    test_sse_usage_lib.lua     Lua unit tests for sse_usage_lib
    run.sh                     Podman-based resty CLI runner
  config/
    test_apisix_yaml.sh        Validate apisix.yaml
    test_config_yaml.sh        Validate config.yaml
    test_compose.sh            Validate docker-compose.yml
    test_dockerfile.sh         Validate Dockerfile.apisix
    test_patterns_json.sh      Validate redact-patterns.json
    test_clickhouse_sql.sh     Validate clickhouse-init.sql
    test_vector_toml.sh        Validate vector.toml
    test_grafana_provisioning.sh  Validate Grafana datasources/dashboard/prometheus
    test_cost_calc.sh          Validate cost_calc.lua module (21 tests, runs in container luajit)
    run.sh                     Run all config tests
  reconciler/
    test_reconciler.sh         Reconciler script tests
  integration/
    test_stack_up.sh           Podman stack bring-up and health
    test_key_resolver.sh       key-resolver plugin black-box test
    test_route_relay.sh        Route relay to upstream test
    test_grafana.sh            Grafana/Prometheus black-box test
    test_data_flow.sh          APISIX-Vector-ClickHouse data flow test
    test_reconciler_exec.sh    Reconciler execution test
    run.sh                     Run all integration tests
  e2e/
    test_zen_chat.sh           End-to-end chat completion
    test_zen_stream.sh         End-to-end SSE streaming
    test_redact_e2e.sh         End-to-end PII redaction header
    test_stream_redact.sh      End-to-end SSE redaction + restore
    test_invalid_model.sh      End-to-end invalid model handling
    run.sh                     Run all E2E tests
  ci/
    test_hooks.sh              CI hook verification
  run_all.sh                   Run all stages in order
```

---

## 6. Stage 1: Lua Unit Tests

### 6.1 Scope

Test the pure functions in `plugins/custom/redact_lib.lua`:

- `luhn_valid(card_number)`: Luhn checksum validation
- `load_patterns(filepath)`: Pattern file loading and dictionary
  building. Returns `data, dict_alt` (dict_alt may be nil).
- `redact_text(text, patterns, dict_alt, counters, token_map, redact_ips)`:
  PII redaction
- `restore_with_key(text, key)`: Token re-hydration

### 6.2 Approach

Tests run via the `resty` CLI inside the APISIX Podman image. The
`resty` binary is at `/usr/bin/resty` in `apache/apisix:3.17.0-debian`.
It provides:

- `ngx.re.gsub` (PCRE regex via lua-resty-core)
- `cjson.safe` (JSON encoding/decoding)
- Standard Lua module system (`require`)

No dependency injection needed. The test file does `require("redact_lib")` and
calls each function with assert-based checks. A pass/fail counter
is maintained and the script exits non-zero on any failure.

### 6.3 Runner

```bash
tests/lua/run.sh
```

Uses Podman to run `resty` inside the APISIX image. Mounts the
plugin source, patterns file, and test file into the container.
The `-I /plugins/custom` flag adds the plugin directory to the
Lua module search path so `require("redact_lib")` resolves.

### 6.4 Test Cases

**luhn_valid:**

| # | Input | Expected | Description |
|---|-------|----------|-------------|
| 1 | `4111111111111111` | true | Valid Visa test number |
| 2 | `5500000000000004` | true | Valid Mastercard test number |
| 3 | `4111111111111112` | false | Invalid (off by one) |
| 4 | `1234567890123456` | false | Invalid checksum |
| 5 | `4111 1111 1111 1111` | true | Valid with spaces |
| 6 | `4111-1111-1111-1111` | true | Valid with dashes |
| 7 | `abcd` | false | Non-numeric input |

**load_patterns:**

| # | Input | Expected | Description |
|---|-------|----------|-------------|
| 1 | `conf/redact-patterns.json` | data table, 6 regex, dict_alt non-nil | Normal load |
| 2 | `/nonexistent/file.json` | nil, error | File not found |
| 3 | invalid JSON content | nil, error | JSON decode failure |

**redact_text:**

| # | Input text | Expected token | Description |
|---|-----------|----------------|-------------|
| 1 | Contact john@example.com | `[EMAIL_1]` | Email redaction |
| 2 | SSN: 123-45-6789 | `[SSN_1]` | SSN redaction |
| 3 | Card: 4111111111111111 | `[CREDIT_CARD_1]` | Valid Luhn card |
| 4 | Card: 1234567890123456 | unchanged | Invalid Luhn, not redacted |
| 5 | String with `sk-` prefix, 20+ alphanumeric chars | `[API_KEY_1]` | API key redaction |
| 6 | Call +1-800-555-1234 | `[PHONE_1]` | Phone redaction |
| 7 | Token: eyJhbGci.eyJzdWI.sflKxwR | `[JWT_1]` | JWT redaction |
| 8 | Working at Acme Corporation | `[DICTIONARY_1]` | Dictionary match |
| 9 | John Smith at john@example.com | `[DICTIONARY_1]` + `[EMAIL_1]` | Multiple PII types |
| 10 | Hello world | unchanged | No PII present |
| 11 | (empty string) | (empty string) | Empty input |
| 12 | IP: 192.168.1.1 (redact_ips=true) | `[IPV4_1]` | IPv4 with flag on |
| 13 | IP: 192.168.1.1 (redact_ips=false) | unchanged | IPv4 with flag off |

**restore_with_key:**

| # | Input text | Token map | Expected | Description |
|---|-----------|-----------|----------|-------------|
| 1 | `[EMAIL_1]` | `[EMAIL_1]` = john@example.com | john@example.com | Single token |
| 2 | `[EMAIL_1] [SSN_1]` | two entries | both restored | Multiple tokens |
| 3 | `[UNKNOWN_1]` | empty map | `[UNKNOWN_1]` | Token not in map |
| 4 | (empty) | empty map | (empty) | Empty text |

### 6.5 Files

- `tests/lua/test_redact_lib.lua` (44 assertions covering
  `luhn_valid`, `load_patterns`, `redact_text`, `restore_with_key`)
- `tests/lua/test_sse_usage_lib.lua` (45 assertions covering SSE
  usage parsing across complete/truncated/chunked event streams)
- `tests/lua/run.sh`

Total Stage 1 assertions: 89 (44 + 45).

---

## 7. Stage 2: Config Validation Tests

### 7.1 Scope

Validate all configuration files for structural correctness and
expected values. Uses `jq` for JSON, Python `yaml.safe_load` for
YAML, and `grep` for text-based assertions.

### 7.2 Test Cases

**apisix.yaml** (`test_apisix_yaml.sh`):

| # | Assertion |
|---|-----------|
| 1 | Valid YAML (parseable) |
| 2 | Exactly 2 routes |
| 3 | First route id is `relay-opencode` |
| 4 | First route uri is `/opencode/*` |
| 5 | Second route id is `relay-opencode-federated` |
| 6 | Second route uri is `/opencode_federated/*` |
| 7 | Upstream scheme is `https` |
| 8 | Upstream node is `opencode.ai:443` |
| 9 | `proxy-rewrite` present with regex_uri that strips prefix |
| 10 | `proxy-rewrite` regex_uri replacement is `/zen/go/` |
| 11 | `key-resolver` plugin present |
| 12 | `ai-rate-limiting` plugin present |
| 13 | `prometheus` plugin present |
| 14 | `http-logger` plugin present |
| 15 | `http-logger` has no `log_format` field |
| 16 | `http-logger` `include_req_body` is true |
| 17 | `http-logger` `include_resp_body` is true |
| 18 | `http-logger` `max_req_body_bytes` and `max_resp_body_bytes` are 8192 |
| 19 | `http-logger` uri is `http://vector:8080/ingest` |
| 20 | `proxy-buffering` plugin present |
| 21 | `redact` plugin present |
| 22 | `sse-usage` plugin present |

**config.yaml** (`test_config_yaml.sh`):

| # | Assertion |
|---|-----------|
| 1 | Valid YAML |
| 2 | `deployment.role` is `data_plane` |
| 3 | `deployment.config_provider` is `yaml` |
| 4 | `redact` in plugins list |
| 5 | `key-resolver` in plugins list |
| 6 | `proxy-rewrite` in plugins list |
| 7 | `resolver` is `no` (disables Nginx static resolver) |
| 8 | `lua_shared_dict` has `redact_state` |
| 9 | `lua_shared_dict` has `key_cache` |
| 10 | `lua_shared_dict` has `gateway-cache` (cost_calc pricing cache, 2m) |
| 11 | `OPENCODE_API_KEY` referenced via env.var |
| 12 | `OPENBAO_TOKEN` referenced for key-resolver OpenBao access |

**docker-compose.yml** (`test_compose.sh`):

| # | Assertion |
|---|-----------|
| 1 | Valid YAML |
| 2 | Exactly 6 services |
| 3 | Has `apisix` service |
| 4 | Has `clickhouse` service |
| 5 | Has `vector` service |
| 6 | Has `openbao` service (custom build via `Dockerfile.openbao`) |
| 7 | `openbao` service has persistent volume |
| 8 | Has `prometheus` service |
| 9 | Prometheus uses `prom/prometheus` image |
| 10 | Prometheus exposes port 9092 |
| 11 | Prometheus container name is `prometheus` |
| 12 | Has `grafana` service |
| 13 | Grafana uses `grafana/grafana` image |
| 14 | Grafana exposes port 3030 |
| 15 | Grafana container name is `grafana` |
| 16 | Grafana installs clickhouse datasource plugin |
| 17 | APISIX exposes port 9080 |
| 18 | APISIX mounts `apisix.yaml` |
| 19 | APISIX mounts `config.yaml` |
| 20 | APISIX mounts `redact-patterns.json` |
| 21 | APISIX `depends_on` includes `openbao` |
| 22 | ClickHouse mounts `clickhouse-init.sql` |
| 23 | Vector mounts `vector.toml` |
| 24 | Vector exposes port 8080 |
| 25 | Networks: `gateway` and `dataops` |

**Dockerfile.apisix** (`test_dockerfile.sh`):

| # | Assertion |
|---|-----------|
| 1 | Base image is `apache/apisix:3.17.0-debian` |
| 2 | Copies `plugins/custom/` directory |
| 3 | Copies `conf/config.yaml` |
| 4 | Copies `conf/redact-patterns.json` |
| 5 | Copies `sse-usage.lua` |
| 6 | Copies `sse_usage_lib.lua` |

**GAP (2026-07-07):** `cost_calc.lua` and `key-meta.lua` are NOT in the
Dockerfile COPY directives. See §14.7 R-32. The `test_dockerfile.sh` test
passes because it only checks for the files listed above - it does not
assert the absence of other custom plugins. A new assertion should be added
once the COPY directives are fixed.

**redact-patterns.json** (`test_patterns_json.sh`):

| # | Assertion |
|---|-----------|
| 1 | Valid JSON |
| 2 | Has `regex` array with 6 entries |
| 3 | Has `dictionary` array with 2 entries |
| 4 | `credit_card` entry has `luhn_check: true` |
| 5 | Each regex entry has `kind` and `pattern` fields |

**clickhouse-init.sql** (`test_clickhouse_sql.sh`):

| # | Assertion |
|---|-----------|
| 1 | Creates database `llm_gateway` |
| 2 | Creates table `request_log` |
| 3 | Creates table `billing_ledger` |
| 4 | Creates table `billing_discrepancies` |
| 5 | `billing_ledger` has `Decimal64(6)` for cost |
| 6 | TTL `13 MONTH` on tables |
| 7 | `ORDER BY` leads with low-cardinality keys |

**vector.toml** (`test_vector_toml.sh`):

| # | Assertion |
|---|-----------|
| 1 | Source type `http_server` |
| 2 | Address `0.0.0.0:8080` |
| 3 | Path `/ingest` |
| 4 | Sink type `clickhouse` |
| 5 | Endpoint `http://clickhouse:8123` |
| 6 | Table `request_log` |
| 7 | Model extracted via `parse_json` (not `parse_regex`) |
| 8 | `database` set to `llm_gateway` |
| 9 | `skip_unknown_fields` is true |
| 10 | Remap transform parses request/response body |
| 11 | Token usage fields extracted (`prompt_tokens`, `completion_tokens`, `total_tokens`) |
| 12 | Header fields extracted (`redact_active`, `redact_token_count`, `api_key_id`) |

**Grafana provisioning** (`test_grafana_provisioning.sh`):

| # | Assertion |
|---|-----------|
| 1 | `conf/grafana/datasources/` provisioning dir exists |
| 2 | Datasource file for Prometheus exists |
| 3 | Prometheus datasource `url` is `http://prometheus:9090` |
| 4 | Prometheus datasource `access` is `proxy` |
| 5 | Prometheus datasource `isDefault` is true |
| 6 | ClickHouse datasource file exists |
| 7 | ClickHouse datasource `host` points to `clickhouse:8123` |
| 8 | ClickHouse datasource `protocol` is `http` |
| 9 | ClickHouse datasource uses `llm_gateway` database |
| 10 | `conf/grafana/dashboards/` provisioning dir exists |
| 11 | `gateway-overview.json` is valid JSON |
| 12 | Dashboard has `title` containing `gateway` |
| 13 | Dashboard has `uid` set |
| 14 | Dashboard has at least one panel |
| 15 | Panel references Prometheus datasource |
| 16 | Panel has a `targets` array with PromQL query |
| 17 | Panel type is `timeseries` or `stat` |
| 18 | Dashboard has `time` range picker |
| 19 | Dashboard has `refresh` interval set |
| 20 | `conf/prometheus.yml` is valid YAML |
| 21 | `prometheus.yml` `scrape_interval` configured |
| 22 | `prometheus.yml` scrape target includes `apisix` |
| 23 | `prometheus.yml` scrape target includes `prometheus` (self) |
| 24 | Grafana dashboard provisioning config points to `/etc/grafana/provisioning/dashboards` |
| 25 | Datasource provisioning config points to `/etc/grafana/provisioning/datasources` |

### 7.3 Runner

```bash
tests/config/run.sh
```

Runs all 8 config test scripts sequentially. Exits 0 on all pass.

---

## 8. Stage 3: Reconciler Shell Tests

### 8.1 Scope

Validate `res/scripts/reconciler.sh` for syntax, strict mode, error
handling, and structure.

### 8.2 Test Cases

| # | Assertion | How |
|---|-----------|-----|
| 1 | Valid bash syntax | `bash -n` |
| 2 | `set -euo pipefail` present | grep |
| 3 | `CLICKHOUSE_HOST` has default | grep `:-clickhouse` |
| 4 | `CLICKHOUSE_PORT` has default | grep `:-8123` |
| 5 | Error handling on query failure | grep `exit 1` after error block |
| 6 | Empty results handled gracefully | grep `nothing to reconcile` |
| 7 | TODO comment for upstream API queries | grep `TODO` |

### 8.3 Files

- `tests/reconciler/test_reconciler.sh`

---

## 9. Stage 4: Podman Stack Integration Tests

### 9.1 Scope

Start the full gateway stack (APISIX, ClickHouse, Vector) using
Podman and verify it is operational. Black-box testing: send HTTP
requests, check responses. No APISIX admin API access.

### 9.2 Prerequisites

The `dataops_default` external network must exist:

```bash
podman network create dataops_default 2>/dev/null || true
```

### 9.3 Test Cases

| # | Test | Expected |
|---|------|----------|
| 1 | Build APISIX image | Exit 0 |
| 2 | Start stack | All services running |
| 3 | APISIX responds on port 9080 | HTTP response (any status) |
| 4 | `key-auth` rejects without `apikey` header | 401 |
| 5 | `key-auth` rejects with wrong key | 401 |
| 6 | Route exists (correct key reaches upstream) | Non-404 response |
| 7 | Vector listening on port 8080 | Connection accepted |
| 8 | ClickHouse listening on port 8123 | HTTP response |
| 9 | ClickHouse tables exist | `SELECT count()` succeeds |
| 10 | Tear down stack | Exit 0 |

### 9.4 Files

- `tests/integration/test_stack_up.sh`
- `tests/integration/test_key_auth.sh`
- `tests/integration/test_route_relay.sh`
- `tests/integration/run.sh`

### 9.5 Approach

Uses `podman-compose` to start the stack defined in
`res/docker/docker-compose.yml`. Health checks use `curl` with
retry loops. The test script tears down the stack on exit
(including on failure) via a `trap` handler.

---

## 10. Stage 5: CI Hook Verification

### 10.1 Scope

Verify that pre-commit and pre-push hooks are installed,
executable, and reference the correct CI scripts.

### 10.2 Test Cases

| # | Test | Expected |
|---|------|----------|
| 1 | `.git/hooks/pre-commit` exists and is executable | Exit 0 |
| 2 | `.git/hooks/pre-push` exists and is executable | Exit 0 |
| 3 | `pre-commit` references `check-banned-words` | grep match |
| 4 | `pre-commit` references `block-sensitive-files` | grep match |
| 5 | `pre-commit` references `gitleaks` | grep match |
| 6 | `pre-push` references `ci-check-push` | grep match |
| 7 | `pre-push` references `check-dead-code` | grep match |
| 8 | `.pre-commit-config.yaml` exists | Exit 0 |
| 9 | `banned_words.yaml` exists in CI repo | Exit 0 |

### 10.3 Files

- `tests/ci/test_hooks.sh`

### 10.4 Approach

Verifies hook presence and configuration without creating test
commits. This avoids mutating git history. The hooks are exercised
on every real commit, so functional testing is implicit.

---

## 11. Stage 6: End-to-End Live API Tests

### 11.1 Scope

Send real chat completion requests through the APISIX gateway to
the OpenCode Go upstream. Verify the full request/response
lifecycle including SSE streaming and telemetry logging.

These are **live API tests** gated behind `RUN_LIVE_API_TESTS=1`.
They are skipped by default (`make test`) and only run with
`make test-live`. They require upstream API credits and will
fail if the upstream key is out of balance.

### 11.2 Prerequisites

- Running APISIX stack (Stage 4)
- `OPENCODE_API_KEY` set in environment (from `.env`)
- `GATEWAY_API_KEY` set in environment (from `.env`)
- `RUN_LIVE_API_TESTS=1` (set by `make test-live`)
- Outbound HTTPS to `opencode.ai`

### 11.3 Test Cases

| # | Test | Model | Expected |
|---|------|-------|----------|
| 1 | Non-streaming chat | `big-pickle` | 200, `choices[0].message.content` non-empty |
| 2 | Streaming chat | `big-pickle` | 200, `Content-Type: text/event-stream`, SSE events |
| 3 | Different model | `mimo-v2.5-free` | 200, valid response |
| 4 | Redaction header | `big-pickle` + PII in prompt | `X-Redact-Active: 1` header in response |
| 5 | Telemetry logged | any | ClickHouse `request_log` has new row |

### 11.4 Request Format

```bash
curl -X POST http://localhost:9080/zen/v1/chat/completions \
  -H "apikey: $GATEWAY_API_KEY" \
  -H "Authorization: Bearer $OPENCODE_ZEN_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"big-pickle","messages":[{"role":"user","content":"Say hello"}],"stream":false}'
```

Two auth headers:
- `apikey`: gateway key (`$GATEWAY_API_KEY`) for APISIX `key-auth`
  plugin validation
- `Authorization: Bearer`: Zen API key (`$OPENCODE_ZEN_API_KEY`)
  for upstream authentication

APISIX validates the `apikey` header via `key-auth`, then forwards
the request (including the `Authorization` header) to Zen. Zen
validates the Bearer token.

### 11.5 Redaction Verification

Black-box testing cannot inspect the request body APISIX sends to
Zen. The E2E test verifies redaction indirectly:

- Send a prompt containing PII (e.g. an email address)
- Check the response for `X-Redact-Active: 1` header
- Verify the response body does not contain the original PII
  (the LLM should not echo it back since it was redacted before
  reaching the upstream)

Full redaction verification (inspecting the upstream request) is
covered by the Lua unit tests in Stage 1, which test `redact_text`
directly.

### 11.6 Files

- `tests/e2e/test_zen_chat.sh`
- `tests/e2e/test_zen_stream.sh`
- `tests/e2e/test_redact_e2e.sh`
- `tests/e2e/run.sh`

---

## 12. Execution Plan

### 12.1 Commit Sequence

Commits A+B are already pushed as `4c3b6b0`.
Commit B2 is already pushed as `77e2649`.

| Commit | Content | Type |
|--------|---------|------|
| A+B (done) | `apisix.yaml`, `OPENCODE-INTEGRATION.md`, `TEST-PLAN.md` | fix |
| B2 (done) | Revised `TEST-PLAN.md` (agentic gaps closed) | docs |
| C | `redact_lib.lua` + refactored `redact.lua` | refactor |
| D | Lua unit tests + runner (Stage 1) | test |
| E | Config validation tests (Stage 2) | test |
| F | Reconciler shell tests (Stage 3) | test |
| G | Podman stack integration tests (Stage 4) | test |
| H | CI hook verification (Stage 5) | test |
| I | End-to-end Zen API tests (Stage 6) | test |
| J | Makefile + coverage config | chore |

### 12.2 Agentic Parallelization Analysis

All stages C through J are implemented by parallel task agents.
The orchestrator (main agent) handles only: launching agents,
committing in order, and pushing after each commit.

#### Write-Time Dependency Matrix

No stage blocks another at write time. Every agent reads
specifications from this document and existing source files.
No agent needs another agent's output to write its files.

| Stage | Writes To | Reads From | Blocks Others At Write Time? |
|-------|-----------|------------|------------------------------|
| C | `plugins/custom/redact_lib.lua`, `plugins/custom/redact.lua` | existing `redact.lua`, this plan sec 2 | No |
| D | `tests/lua/test_redact_lib.lua`, `tests/lua/run.sh` | this plan sec 6 (API spec + test cases), existing `redact.lua` | No |
| E | `tests/config/*.sh` (8 files) | `conf/*`, `res/docker/*`, this plan sec 7 | No |
| F | `tests/reconciler/test_reconciler.sh` | `res/scripts/reconciler.sh`, this plan sec 8 | No |
| G | `tests/integration/*.sh` (4 files) | `res/docker/docker-compose.yml`, this plan sec 9 | No |
| H | `tests/ci/test_hooks.sh` | `.git/hooks/*`, CI repo, this plan sec 10 | No |
| I | `tests/e2e/*.sh` (4 files) | `conf/apisix.yaml`, this plan sec 11 | No |
| J | `Makefile`, `config/coverage_thresholds.yaml` | this plan sec 12.3-12.4 (path layout) | No |

#### Runtime-Only Dependencies (Verified At Test Time, Not Write Time)

| Constraint | Why | When Verified |
|------------|-----|---------------|
| D tests must run against C's `redact_lib.lua` | D calls functions defined by C | Final test run |
| J Makefile targets must reference existing test dirs | J references paths from this plan | Final test run |

These are runtime constraints, not write-time constraints. Both
agents follow the same specification in this document, so their
outputs are compatible by construction.

#### Execution Waves

**Wave 1: All 8 agents launched simultaneously (C, D, E, F, G, H, I, J)**

Each agent receives:
- The relevant section of this test plan
- Paths to existing source files to read
- The API specification (for D) or path layout (for J)
- Banned words list and file length constraints

**Wave 2: Sequential commits in stage order (orchestrator only)**

After all agents complete, the orchestrator commits and pushes
in this exact order:

1. Commit C (refactor) - stage and push
2. Commit D (test) - stage and push
3. Commit E (test) - stage and push
4. Commit F (test) - stage and push
5. Commit G (test) - stage and push
6. Commit H (test) - stage and push
7. Commit I (test) - stage and push
8. Commit J (chore) - stage and push

Commit order is fixed regardless of agent completion order. If
agent E finishes before agent C, E's files sit on disk until the
orchestrator reaches step 3.

**Wave 3: Run all tests, verify pass**

Execute `tests/run_all.sh` (written by agent J). All 6 stages
must pass with exit code 0.

### 12.3 Makefile Integration

Update `Makefile` targets:

| Target | Action |
|--------|--------|
| `lint` | `bash -n` on all `.sh` files; YAML validation via Python |
| `type-check` | Lua syntax check via `resty -e "loadfile(...)"` in Podman |
| `test` | `tests/run_all.sh` (stages 1 through 5; skip 6 unless `OPENCODE_ZEN_API_KEY` set) |
| `check` | `lint` + `type-check` + `test` |
| `check-push` | `check` + stage 6 (if Zen key available) |

### 12.4 Coverage Config

Update `config/coverage_thresholds.yaml` to reflect the Lua and
shell test structure:

```yaml
unit:
  path: tests/lua
  min_coverage: 1
  source_path: plugins/custom
  runner: "tests/lua/run.sh"
  coverage: "false"

config:
  path: tests/config
  min_coverage: 1
  source_path: conf
  runner: "tests/config/run.sh"
  coverage: "false"

integration:
  path: tests/integration
  min_coverage: 5
  source_path: .
  runner: "tests/integration/run.sh"
  coverage: "false"
```

The current config expects Python pytest tests, which do not exist
in this project. Lua unit tests cover pure logic; config tests are
pass/fail assertions (no coverage measurement); integration and
E2E tests are black-box (no coverage measurement).

---

## 13. Success Criteria

- All 6 stages pass with exit code 0
- Lua unit tests cover all pure functions in `redact_lib.lua`
- Config validation catches any misconfiguration before deployment
- Podman stack starts and responds to requests
- `key-auth` rejects unauthenticated requests
- End-to-end request through APISIX to Zen returns a valid LLM
  response
- SSE streaming works through the gateway
- PII redaction is active (verified by `X-Redact-Active` header and
  by Lua unit tests testing `redact_text` directly)
- Telemetry logs reach ClickHouse via Vector

---

## 14. Audit Findings and Remediation Plan

A comprehensive three-agent audit was conducted on 2026-07-06
covering configuration, plugin implementation, test suite
comprehensiveness, and documentation completeness.

### 14.1 Critical Issues (P0)

#### P0-1: Billing Pipeline Not Wired

The `billing_ledger` table exists in `clickhouse-init.sql` with
full token/cost columns but is never populated. Vector
(`vector.toml`) only writes to `request_log`. No sink, transform,
or job writes to `billing_ledger`. The entire billing-grade
ledger is an empty schema.

**Files:** `conf/vector.toml:20`, `conf/clickhouse-init.sql:26-53`
**Fix:** Add a second Vector sink for `billing_ledger`, or add a
Lua log-phase plugin that parses response body for `usage` fields
and inserts billing rows via an HTTP call to ClickHouse.

#### P0-2: No Token Usage Capture

The `http-logger` `log_format` in `apisix.yaml` captures only 7
fields (provider, model, stream, method, uri, status, latency).
Missing: `prompt_tokens`, `completion_tokens`, `total_tokens`,
`cost`, `client_ip`, `request_size`, `response_size`,
`api_key_id`, `redact_active`, `redact_token_count`. With
`include_resp_body: false`, token usage data from the response
body is never captured.

**Files:** `conf/apisix.yaml:24-33`
**Fix:** Enrich `log_format` with Nginx variables and response
body parsing. Consider a custom `body_filter` Lua snippet that
captures `usage` from the final response chunk and stores it in
`ctx` for the `log` phase. Alternatively, set
`include_resp_body: true` and parse in Vector's remap transform.

#### P0-3: Reconciler Is Incomplete

`reconciler.sh` queries ClickHouse for gateway-side totals and
logs them, but the upstream provider API comparison is a TODO
(line 38-39). The `TOLERANCE` variable is defined but never used.
No divergence is calculated. `billing_discrepancies` table is
never written to. The query does not group by `tenant_id`.

**Files:** `res/scripts/reconciler.sh:5,14,38-39`
**Fix:** Either implement the upstream comparison (query Zen API
for usage data, compare, calculate divergence, insert into
`billing_discrepancies`) or mark the reconciler as v2 and remove
the dead `TOLERANCE` variable and `billing_discrepancies` table
from v1 scope.

#### P0-4: E2E Redact Test Flawed

`test_redact_e2e.sh` asserts the response body does not contain
the original PII email. However, the redact plugin *restores*
tokens to original PII in the response (`body_filter` calls
`restore_with_key`). If the model echoes the email, it would
appear restored in the response. The test passing only proves
the model did not echo the email, not that redaction worked
upstream.

**Files:** `tests/e2e/test_redact_e2e.sh`
**Fix:** After sending a request with PII, query ClickHouse
`request_log` (or inspect http-logger output) to verify the
logged request body contains `[EMAIL_1]` (the redacted token),
not the raw email address. This proves the upstream received the
redacted version.

#### P0-5: No Data-Flow Verification Test

No test sends a request through the gateway and verifies a row
appears in ClickHouse with correct fields. The integration test
checks that `request_log` table *exists* (count=0) but never
verifies it *receives rows* after a request. The entire
APISIX-to-Vector-to-ClickHouse data path is untested.

**Files:** `tests/integration/test_stack_up.sh`
**Fix:** Add a test case that sends a chat request through the
gateway, waits 2-3 seconds for Vector to process, then queries
ClickHouse `SELECT count() FROM llm_gateway.request_log` and
asserts count > 0. Further assert the row contains the correct
model and status values.

### 14.2 Code Bugs (P1)

#### P1-1: Invalid APISIX Variable

`$upstream_latency_ms` in `apisix.yaml:33` is not a standard
APISIX built-in variable. APISIX exposes `$upstream_response_time`
(seconds, float). This field will produce empty or invalid data.

**Fix:** Replace with `$upstream_response_time` and rename the
log_format key to `upstream_response_time_s`, or multiply in a
Lua log phase.

#### P1-2: Dictionary Escaping Bug

`redact_lib.lua:34` uses Lua pattern escaping (`%%%1`) for
dictionary entries, but the escaped string is fed to
`ngx.re.gsub` which uses PCRE where the escape character is `\`.
For entries with regex metacharacters (`.`, `(`, `)`, `+`, `?`,
`*`), the escaping is wrong. Latent because current dictionary
entries have no metacharacters.

**Fix:** Replace `entry:gsub("([^%w%s])", "%%%1")` with
`entry:gsub("([^%w%s])", "\\%1")` to produce PCRE-escaped strings.

#### P1-3: Dockerfile Duplicate COPY

`Dockerfile.apisix:4` copies `redact.lua` to
`/usr/local/apisix/apisix/plugins/redact.lua` (parent `plugins/`
dir) in addition to line 3 which copies the entire `plugins/custom/`
directory. This creates a redundant copy that could cause
double-registration if APISIX auto-discovers plugins in the
parent directory.

**Fix:** Remove line 4. The `extra_lua_path` in `config.yaml`
already resolves `require("apisix.plugins.custom.redact")` to the
correct path. If APISIX requires the plugin at
`apisix.plugins.redact` (without `custom`), update `config.yaml`
`extra_lua_path` instead.

#### P1-4: cjson.encode Failure Unhandled

`redact.lua:86` calls `cjson.encode(parsed)` to re-encode the
redacted request body. If encode fails (returns nil), the result
is passed to `ngx.req.set_body_data(new_body, #new_body)` which
will error on `#nil`. No pcall wrap.

**Fix:** Wrap in pcall. On failure in `on_error: closed` mode,
return 503. In `on_error: open` mode, pass through the original
body.

#### P1-5: Non-Chat Body Passthrough Violates Rule 13

`redact.lua:57-59` returns without redaction when the request
body is not valid JSON or lacks a `messages` array. No error
header is set. PII in non-chat-shaped requests passes to upstream
unredacted with no indication. This violates AGENTS.md Rule 13
(no unreported reduced behavior) and the plugin's own test plan
assertion (PLUGIN-REDACT-LUA.md section 12).

**Fix:** Set an `X-Redact-Error: non-chat-body` header when
redaction is skipped due to body shape, so callers are aware that
no redaction was applied.

#### P1-6: Patterns Loaded Every Request

`redact.lua:44` calls `load_patterns()` on every request in the
`access` phase. This performs file I/O and JSON parse on every
single request. The `redact_state` shared dict is allocated in
`config.yaml` but never used for caching.

**Fix:** Cache patterns in the `redact_state` shared dict with
an mtime check. Load from disk only when the file has changed.

#### P1-7: Dead Configuration

`config.yaml` allocates `semcache_state: 4m` shared dict for the
v2 semantic-cache plugin that does not exist. `ai-proxy` and
`ai-proxy-multi` are listed in the plugins array but no route
uses them. These waste memory and create confusion.

**Fix:** Remove `semcache_state` from shared dicts. Remove
`ai-proxy` and `ai-proxy-multi` from the plugins list (re-add
when v2 semantic cache or multi-provider routing is implemented).

### 14.3 Test Gaps (P1)

| Gap | Current State | Required Test |
|-----|--------------|---------------|
| `redact.lua` plugin: 0 unit tests | 153 lines of access/header_filter/body_filter/log logic untested | Unit tests for body parsing, stream_mode reject, on_error closed/open, header_filter X-Redact-Active |
| No streaming + redaction E2E | `body_filter` stream branch unexercised | E2E test with `stream: true` + PII in prompt, verify redaction + restore on SSE chunks |
| No rate-limit enforcement test | `ai-rate-limiting` 429 never triggered | Send N+1 requests rapidly, verify 429 on the (N+1)th |
| No Prometheus metrics test | `/apisix/prometheus/metrics` never curled | Curl metrics endpoint, verify gateway-specific metrics present |
| No Vector-to-ClickHouse flow test | No event posted to `/ingest` and verified in DB | Post a test log entry to Vector `/ingest`, query ClickHouse, verify row appears |
| Reconciler never executed | 7 assertions are all grep/syntax checks | Run `reconciler.sh` against ClickHouse with seed data, verify row-logging and empty-result paths |
| No upstream error handling test | No 500/502/503 from upstream simulated | Send request to invalid model, verify error response propagation |
| No invalid-model E2E test | All E2E tests use valid free models | Send request with non-existent model, verify 4xx error |
| No concurrent requests test | All tests are sequential | Send 10 parallel curls, verify all complete without errors |
| No ClickHouse log content verification | Row count checked, content never validated | After E2E request, query `request_log` and assert model/status/latency match the request |
| `token_map` correctness unverified | Token presence asserted, mapping value never checked | Assert `token_map["[EMAIL_1]"] == "john@example.com"` |
| Counter increments unverified | Never asserts `counters["EMAIL"] == 2` after two emails | Add counter assertions to Lua unit tests |
| Config test value gaps | Plugin presence checked, config values mostly unchecked | Validate `ai-rate-limiting` limit/window/code, `http-logger` full log_format, `redact` patterns_file path |

### 14.4 Documentation Gaps (P1)

| Issue | Fix |
|-------|-----|
| `DEPLOYMENT.md` describes enterprise architecture (OIDC/LDAP/ai-proxy-multi) not the actual Zen relay | Update to reflect single-route Zen relay, or mark enterprise sections as "future/v2" |
| `README.md` status says "implementation not started" | Update to reflect actual implementation state (plugin, config, stack, tests all exist) |
| `ci-profile.yaml` declares `languages: [rust]` | Change to `[lua, shell]` |
| Docs use different column name than code for redact count field | Align docs to match code (`redact_token_count`) |
| Docs say Vector writes to `llm_billing_ledger`, code writes to `request_log` | Update docs to match actual Vector sink configuration |
| `TEST-PLAN.md` section 12.4 shows `min_coverage: 0`, actual config has `min_coverage: 1` | Update plan to match actual thresholds |
| `TEST-PLAN.md` section 12.3 says `resty -bl`, actual Makefile uses `loadfile()` | Update plan to match actual Makefile |
| `PLUGIN-FOUNDATION.md` and `PROPOSAL` reference `redact-patterns.yaml` (YAML), actual file is `.json` | Update docs to reference JSON format |

### 14.5 Deferred Features (P2, Intentional)

| Feature | Status |
|---------|--------|
| Semantic cache plugin | v2 deferred (documented in `PLUGIN-SEMANTIC-CACHE.md`) |
| NER sidecar | v2 deferred (documented in `PLUGIN-REDACT-ENGINE.md`) |
| Embedding service | v2 deferred |
| TLS termination at gateway (port 9443) | Port exposed, no certs/SSL config |
| Health checks (Docker/APISIX/upstream) | None configured |
| Multi-tenant auth (OIDC/LDAP) | Not implemented (simplified to key-auth) |
| Multi-provider failover | Not implemented (single Zen upstream) |
| Alerting rules | Documented in `DEPLOYMENT.md` section 9.3 but not configured |

### 14.6 Remediation Backlog

Priority-ordered list of work items to close the audit gaps:

| ID | Priority | Title | Type |
|----|----------|-------|------|
| R-01 | P0 | Wire billing pipeline (token capture to ClickHouse) | feat |
| R-02 | P0 | Fix E2E redact test to verify upstream received tokens | fix |
| R-03 | P0 | Add data-flow integration test (request to ClickHouse row) | test |
| R-04 | P0 | Finish or remove reconciler | fix |
| R-05 | P1 | Fix `$upstream_latency_ms` invalid variable | fix |
| R-06 | P1 | Fix dictionary PCRE escaping in `redact_lib.lua` | fix |
| R-07 | P1 | Remove Dockerfile duplicate COPY | fix |
| R-08 | P1 | Handle `cjson.encode` failure in `redact.lua` | fix |
| R-09 | P1 | Set error header on non-chat body passthrough | fix |
| R-10 | P1 | Cache patterns in shared dict | perf |
| R-11 | P1 | Remove dead config (semcache_state, unused plugins) | chore |
| R-12 | P1 | Add `redact.lua` plugin unit tests | test |
| R-13 | P1 | Add streaming + redaction E2E test | test |
| R-14 | P1 | Add rate-limit enforcement test | test |
| R-15 | P1 | Add Prometheus metrics endpoint test | test |
| R-16 | P1 | Add Vector-to-ClickHouse flow test | test |
| R-17 | P1 | Add reconciler execution test | test |
| R-18 | P1 | Add upstream error handling test | test |
| R-19 | P1 | Add invalid-model E2E test | test |
| R-20 | P1 | Add ClickHouse log content verification | test |
| R-21 | P1 | Add `token_map` and counter assertions to unit tests | test |
| R-22 | P1 | Deepen config validation tests (values not just presence) | test |
| R-23 | P1 | Update `DEPLOYMENT.md` to match Zen relay architecture | docs |
| R-24 | P1 | Update `README.md` status | docs |
| R-25 | P1 | Fix `ci-profile.yaml` language declaration | fix |
| R-26 | P1 | Align doc/code column names and Vector table names | docs |
| R-27 | P1 | Update TEST-PLAN sections 12.3-12.4 to match actual config | docs |
| R-28 | P2 | Add TLS termination or document HTTP-only as v1 scope | feat/docs |
| R-29 | P2 | Add health checks (Docker, APISIX, upstream) | feat |
| R-30 | P2 | Add concurrent requests test | test |
| R-31 | P2 | Add large request body test | test |

### 14.7 Cost Calculator Deployment Gaps (2026-07-07) - ALL RESOLVED

Live verification of `cost_calc.lua` revealed 9 deployment-infrastructure
and correctness issues. The core logic (cost computation, two-pathway
resolution, shared-dict caching) is verified correct - both Pathway A
(upstream cost) and Pathway B (computed via models.dev pricing) produce
correct results in ClickHouse. All 9 issues below have been fixed and
verified with 250 static tests passing.

Full details: `docs/COST-CALC-LUA.md` §18.

| ID | Priority | Title | Type | Spec Ref | Status |
|----|----------|-------|------|----------|--------|
| R-32 | P0 | Add `cost_calc.lua` and `key-meta.lua` COPY to `Dockerfile.apisix` | fix | §18.1 | RESOLVED |
| R-33 | P0 | Add volume mount for all 7 plugins in `docker-compose.yml` | fix | §18.2 | RESOLVED |
| R-34 | P0 | Fix pricing key collision - array storage + cheapest-first sort | fix | §18.3 | RESOLVED |
| R-35 | P1 | Add error handling for `cost_calc.warmup()` return value in `plugin.init()` | fix | §18.4 | RESOLVED |
| R-36 | P1 | Restart Grafana container to deploy dashboard v28 | fix | §18.5 | RESOLVED |
| R-37 | P2 | Remove `0 * cache_write_rate` dead code in `compute_cost` | chore | §18.6 | RESOLVED |
| R-38 | P2 | Add comment explaining `cost_calc` absent from `config.yaml` plugins list | docs | §18.7 | RESOLVED |
| R-39 | P1 | Add end-to-end integration test `tests/integration/test_cost_e2e.sh` | test | §18.8 | RESOLVED |
| R-40 | P1 | Add ClickHouse migration script `conf/clickhouse-migration-cost-source.sql` | fix | §18.9 | RESOLVED |
