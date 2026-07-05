# Test Plan: WORKSPACE-GATEWAY

**Project:** WORKSPACE-GATEWAY
**Platform:** Apache APISIX 3.17.0, OpenCode Zen
**Date:** 2026-07-06

---

## 1. Overview

This document defines the end-to-end testing and verification plan
for the WORKSPACE-GATEWAY project. The gateway uses Apache APISIX
3.17.0 as a relay to OpenCode Zen, with PII redaction, rate
limiting, telemetry logging, and billing-grade token accounting.

- Upstream: OpenCode Zen (`https://opencode.ai/zen/v1`)
- Gateway port: 9080 (HTTP), 9443 (HTTPS)
- Key models: `big-pickle`, `mimo-v2.5-free`,
  `north-mini-code-free`, `nemotron-3-ultra-free`,
  `deepseek-v4-flash-free`

---

## 2. Testing Strategy

Six stages, from fast unit tests to slow end-to-end tests. Each
stage is independently runnable and produces a pass/fail exit code.

| Stage | Scope | Speed | Runner | Dependencies |
|-------|-------|-------|--------|--------------|
| 1 | Lua unit tests (redact.lua) | <5s | Podman + LuaJIT | APISIX image |
| 2 | Config validation | <2s | Shell + jq + Python | None |
| 3 | Reconciler script | <1s | Shell | None |
| 4 | Podman stack integration | <60s | Podman compose | APISIX, ClickHouse, Vector images |
| 5 | CI hook verification | <5s | Shell + git | CI repo |
| 6 | End-to-end Zen API | <30s | Shell + curl | Running stack + Zen key |

Stages 1 through 3 run without network access. Stage 4 requires
Podman image pulls. Stage 6 requires outbound HTTPS to
`opencode.ai`.

---

## 3. Prerequisites

### 3.1 Tools

| Tool | Version | Purpose |
|------|---------|---------|
| Podman | 5.6.2+ | Container runtime for APISIX, ClickHouse, Vector |
| jq | any | JSON validation in config tests |
| Python | 3.10+ | YAML parsing in config tests |
| curl | any | HTTP requests in integration and E2E tests |
| git | any | CI hook verification |

### 3.2 Environment Variables

| Variable | Required For | Source |
|----------|-------------|--------|
| `OPENCODE_ZEN_API_KEY` | Stage 6 | `.env` file |
| `OPENCODE_ZEN_BASE_URL` | Stage 6 | `.env` file |

### 3.3 Files Under Test

| File | Stage |
|------|-------|
| `plugins/custom/redact.lua` | 1 |
| `conf/apisix.yaml` | 2, 4, 6 |
| `conf/config.yaml` | 2 |
| `conf/redact-patterns.json` | 1, 2 |
| `conf/clickhouse-init.sql` | 2 |
| `conf/vector.toml` | 2 |
| `res/docker/docker-compose.yml` | 2, 4, 6 |
| `res/docker/Dockerfile.apisix` | 2, 4 |
| `res/scripts/reconciler.sh` | 3 |

---

## 4. Test File Layout

```
tests/
  lua/
    test_redact.lua            Lua unit tests for redact plugin
    run.sh                     Podman-based test runner
  config/
    test_apisix_yaml.sh        Validate apisix.yaml
    test_config_yaml.sh        Validate config.yaml
    test_compose.sh            Validate docker-compose.yml
    test_dockerfile.sh         Validate Dockerfile.apisix
    test_patterns_json.sh      Validate redact-patterns.json
    test_clickhouse_sql.sh     Validate clickhouse-init.sql
    test_vector_toml.sh        Validate vector.toml
    run.sh                     Run all config tests
  reconciler/
    test_reconciler.sh         Reconciler script tests
  integration/
    test_stack_up.sh           Podman stack bring-up and health
    test_key_auth.sh           key-auth plugin black-box test
    test_route_relay.sh        Route relay to upstream test
    run.sh                     Run all integration tests
  e2e/
    test_zen_chat.sh           End-to-end chat completion
    test_zen_stream.sh         End-to-end SSE streaming
    test_redact_e2e.sh         End-to-end PII redaction
    run.sh                     Run all E2E tests
  ci/
    test_hooks.sh              CI hook verification
  run_all.sh                   Run all stages in order
```

---

## 5. Stage 1: Lua Unit Tests

### 5.1 Scope

Test the pure functions in `plugins/custom/redact.lua`:

- `luhn_valid(card_number)`: Luhn checksum validation
- `load_patterns(filepath)`: Pattern file loading and dictionary
  building
- `redact_text(text, patterns, counters, token_map, redact_ips)`:
  PII redaction
- `restore_with_key(text, key)`: Token re-hydration

### 5.2 Approach

The redact plugin depends on `apisix.core` and OpenResty `ngx` APIs
(`ngx.re.gsub`). These are only available inside the APISIX/OpenResty
runtime. Tests run inside a Podman container based on the APISIX
image, which has LuaJIT and all required modules.

The test file creates a minimal `apisix.core` test module (logging
and schema check) and uses the built-in `ngx` globals from
OpenResty. It then loads `redact.lua` via `dofile()` and tests each
function with assert-based checks. No external test framework
dependency. A pass/fail counter is maintained and the script exits
non-zero on any failure.

### 5.3 Test Cases

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
| 1 | `conf/redact-patterns.json` | data table, 6 regex, dict alternation | Normal load |
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

### 5.4 Files

- `tests/lua/test_redact.lua`
- `tests/lua/run.sh`

### 5.5 Runner

```bash
tests/lua/run.sh
```

Uses Podman to run `luajit` inside the APISIX image. Mounts the
plugin source, patterns file, and test file into the
container. Exits 0 on all pass, non-zero on any failure.

---

## 6. Stage 2: Config Validation Tests

### 6.1 Scope

Validate all configuration files for structural correctness and
expected values. Uses `jq` for JSON, Python `yaml.safe_load` for
YAML, and `grep` for text-based assertions.

### 6.2 Test Cases

**apisix.yaml** (`test_apisix_yaml.sh`):

| # | Assertion |
|---|-----------|
| 1 | Valid YAML (parseable) |
| 2 | Exactly 1 route |
| 3 | Route id is `relay-zen` |
| 4 | Route uri is `/zen/*` |
| 5 | Upstream scheme is `https` |
| 6 | Upstream node is `opencode.ai:443` |
| 7 | No `proxy-rewrite` plugin (path preserved) |
| 8 | `key-auth` plugin present |
| 9 | `ai-rate-limiting` plugin present |
| 10 | `prometheus` plugin present |
| 11 | `http-logger` plugin present |
| 12 | `proxy-buffering` plugin present |
| 13 | `redact` plugin present |
| 14 | Consumer exists with key `opencode-gateway-key` |
| 15 | `http-logger` uri is `http://vector:8080/ingest` |
| 16 | `log_format` provider is `opencode-zen` |

**config.yaml** (`test_config_yaml.sh`):

| # | Assertion |
|---|-----------|
| 1 | Valid YAML |
| 2 | `deployment.role` is `data_plane` |
| 3 | `deployment.config_provider` is `yaml` |
| 4 | `extra_lua_path` includes custom plugins path |
| 5 | `redact` in plugins list |
| 6 | `key-auth` in plugins list |
| 7 | `lua_shared_dict` has `redact_state` |

**docker-compose.yml** (`test_compose.sh`):

| # | Assertion |
|---|-----------|
| 1 | Valid YAML |
| 2 | Has `apisix` service |
| 3 | Has `clickhouse` service |
| 4 | Has `vector` service |
| 5 | APISIX exposes port 9080 |
| 6 | APISIX mounts `apisix.yaml` |
| 7 | APISIX mounts `redact-patterns.json` |
| 8 | ClickHouse mounts `clickhouse-init.sql` |
| 9 | Vector mounts `vector.toml` |
| 10 | Vector exposes port 8080 |
| 11 | Networks: `gateway` and `dataops` |

**Dockerfile.apisix** (`test_dockerfile.sh`):

| # | Assertion |
|---|-----------|
| 1 | Base image is `apache/apisix:3.17.0-debian` |
| 2 | Copies `plugins/custom/` |
| 3 | Copies `conf/config.yaml` |
| 4 | Copies `conf/redact-patterns.json` |

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

### 6.3 Runner

```bash
tests/config/run.sh
```

Runs all 7 config test scripts sequentially. Exits 0 on all pass.

---

## 7. Stage 3: Reconciler Shell Tests

### 7.1 Scope

Validate `res/scripts/reconciler.sh` for syntax, strict mode, error
handling, and structure.

### 7.2 Test Cases

| # | Assertion | How |
|---|-----------|-----|
| 1 | Valid bash syntax | `bash -n` |
| 2 | `set -euo pipefail` present | grep |
| 3 | `CLICKHOUSE_HOST` has default | grep `:-clickhouse` |
| 4 | `CLICKHOUSE_PORT` has default | grep `:-8123` |
| 5 | Error handling on query failure | grep `exit 1` after error block |
| 6 | Empty results handled gracefully | grep `nothing to reconcile` |
| 7 | TODO comment for upstream API queries | grep `TODO` |

### 7.3 Files

- `tests/reconciler/test_reconciler.sh`

---

## 8. Stage 4: Podman Stack Integration Tests

### 8.1 Scope

Start the full gateway stack (APISIX, ClickHouse, Vector) using
Podman and verify it is operational. Black-box testing: send HTTP
requests, check responses. No APISIX admin API access.

### 8.2 Test Cases

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

### 8.3 Files

- `tests/integration/test_stack_up.sh`
- `tests/integration/test_key_auth.sh`
- `tests/integration/test_route_relay.sh`
- `tests/integration/run.sh`

### 8.4 Approach

Uses `podman-compose` (or direct `podman` commands) to start the
stack defined in `res/docker/docker-compose.yml`. Health checks use
`curl` with retry loops. The test script tears down the stack on
exit (including on failure) via a `trap` handler.

---

## 9. Stage 5: CI Hook Verification

### 9.1 Scope

Verify that pre-commit and pre-push hooks fire correctly and catch
violations.

### 9.2 Test Cases

| # | Test | Expected |
|---|------|----------|
| 1 | Pre-commit hooks run on clean tree | Exit 0 |
| 2 | Banned word in staged file | Hook rejects |
| 3 | File exceeding 512 lines | Hook rejects |
| 4 | Commit message missing type prefix | Hook rejects |
| 5 | `Co-authored-by` line in commit | Hook rejects |

### 9.3 Files

- `tests/ci/test_hooks.sh`

### 9.4 Approach

Creates temporary files with known violations, stages them, and
verifies the hook rejects. Cleans up after each test. Does not
modify the actual git history.

---

## 10. Stage 6: End-to-End Zen API Test

### 10.1 Scope

Send real chat completion requests through the APISIX gateway to
OpenCode Zen using free models. Verify the full request/response
lifecycle including SSE streaming, PII redaction, and telemetry
logging.

### 10.2 Prerequisites

- Running APISIX stack (Stage 4)
- `OPENCODE_ZEN_API_KEY` set in environment (from `.env`)
- Outbound HTTPS to `opencode.ai`

### 10.3 Test Cases

| # | Test | Model | Expected |
|---|------|-------|----------|
| 1 | Non-streaming chat | `big-pickle` | 200, `choices[0].message.content` non-empty |
| 2 | Streaming chat | `big-pickle` | 200, `Content-Type: text/event-stream`, SSE events |
| 3 | Different model | `mimo-v2.5-free` | 200, valid response |
| 4 | Redaction active | `big-pickle` + PII in prompt | `X-Redact-Active: 1` header |
| 5 | Telemetry logged | any | ClickHouse `request_log` has new row |

### 10.4 Request Format

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
- `Authorization: Bearer`: Zen API key (`$OPENCODE_ZEN_API_KEY`) for
  upstream authentication

APISIX validates the `apikey` header via `key-auth`, then forwards
the request (including the `Authorization` header) to Zen. Zen
validates the Bearer token.

### 10.5 Files

- `tests/e2e/test_zen_chat.sh`
- `tests/e2e/test_zen_stream.sh`
- `tests/e2e/test_redact_e2e.sh`
- `tests/e2e/run.sh`

---

## 11. Execution Plan

### 11.1 Commit Sequence

| Commit | Content | Type |
|--------|---------|------|
| A | `apisix.yaml` + `OPENCODE-INTEGRATION.md` (current changes) | fix |
| B | `TEST-PLAN.md` + `tests/` directory + Makefile targets | docs |
| C | Lua unit tests + runner (Stage 1) | test |
| D | Config validation tests (Stage 2) | test |
| E | Reconciler shell tests (Stage 3) | test |
| F | Podman stack integration tests (Stage 4) | test |
| G | CI hook verification (Stage 5) | test |
| H | End-to-end Zen API tests (Stage 6) | test |

### 11.2 Makefile Integration

Update `Makefile` targets:

| Target | Action |
|--------|--------|
| `lint` | `bash -n` on all `.sh` files; YAML validation via Python |
| `type-check` | Lua syntax check via Podman (`luajit -bl`) |
| `test` | `tests/run_all.sh` (stages 1 through 5; skip 6 unless `OPENCODE_ZEN_API_KEY` set) |
| `check` | `lint` + `type-check` + `test` |
| `check-push` | `check` + stage 6 (if Zen key available) |

### 11.3 Coverage Config

Update `config/coverage_thresholds.yaml` to reflect the Lua and
shell test structure instead of the auto-generated defaults. The
current config expects Python pytest tests, which do not exist in
this project.

---

## 12. Success Criteria

- All 6 stages pass with exit code 0
- Lua unit tests cover all pure functions in `redact.lua`
- Config validation catches any misconfiguration before deployment
- Podman stack starts and responds to requests
- `key-auth` rejects unauthenticated requests
- End-to-end request through APISIX to Zen returns a valid LLM
  response
- SSE streaming works through the gateway
- PII redaction is active and tokens are restored in responses
- Telemetry logs reach ClickHouse via Vector
