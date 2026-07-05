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

## 2. Architecture: Extract-Testable-Core

The `redact` plugin has two categories of code:

1. **Pure logic** -- Luhn validation, pattern loading, text
   redaction, token restoration. Depends only on `ngx.re.gsub`
   and `cjson.safe`, both available via the `resty` CLI.
2. **Nginx-coupled code** -- request body reading, response header
   manipulation, response body filtering. Depends on `ngx.req`,
   `ngx.arg`, `ngx.header` -- only available inside the Nginx
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
| E2E | Full request to Zen | curl vs running stack + Zen | Yes |

---

## 3. Testing Strategy

Six stages, from fast unit tests to slow end-to-end tests. Each
stage is independently runnable and produces a pass/fail exit code.

| Stage | Scope | Speed | Runner | Dependencies |
|-------|-------|-------|--------|--------------|
| 1 | Lua unit tests (redact_lib.lua) | <5s | `resty` CLI in Podman | APISIX image |
| 2 | Config validation | <2s | Shell + jq + Python | None |
| 3 | Reconciler script | <1s | Shell | None |
| 4 | Podman stack integration | <60s | podman-compose | APISIX, ClickHouse, Vector images |
| 5 | CI hook verification | <5s | Shell + git | CI repo |
| 6 | End-to-end Zen API | <30s | Shell + curl | Running stack + Zen key |

Stages 1 through 3 run without network access. Stage 4 requires
Podman image pulls. Stage 6 requires outbound HTTPS to
`opencode.ai`.

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
| `OPENCODE_ZEN_API_KEY` | Stage 6 | `.env` file |
| `OPENCODE_ZEN_BASE_URL` | Stage 6 | `.env` file |
| `GATEWAY_API_KEY` | Stage 4, 6 | `.env` file |

`GATEWAY_API_KEY` is the APISIX `key-auth` consumer key. Its value
is `opencode-gateway-key` (defined in `conf/apisix.yaml`).

### 4.3 Files Under Test

| File | Stage |
|------|-------|
| `plugins/custom/redact_lib.lua` | 1 |
| `plugins/custom/redact.lua` | 4 (integration) |
| `conf/apisix.yaml` | 2, 4, 6 |
| `conf/config.yaml` | 2 |
| `conf/redact-patterns.json` | 1, 2 |
| `conf/clickhouse-init.sql` | 2 |
| `conf/vector.toml` | 2 |
| `res/docker/docker-compose.yml` | 2, 4, 6 |
| `res/docker/Dockerfile.apisix` | 2, 4 |
| `res/scripts/reconciler.sh` | 3 |

---

## 5. Test File Layout

```
plugins/custom/
  redact_lib.lua               Pure logic (requireable module)
  redact.lua                   Thin adapter (APISIX lifecycle)
tests/
  lua/
    test_redact_lib.lua        Lua unit tests for redact_lib
    run.sh                     Podman-based resty CLI runner
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
    test_redact_e2e.sh         End-to-end PII redaction header
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

No shims needed. The test file does `require("redact_lib")` and
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

- `tests/lua/test_redact_lib.lua`
- `tests/lua/run.sh`

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

### 7.3 Runner

```bash
tests/config/run.sh
```

Runs all 7 config test scripts sequentially. Exits 0 on all pass.

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

## 11. Stage 6: End-to-End Zen API Test

### 11.1 Scope

Send real chat completion requests through the APISIX gateway to
OpenCode Zen using free models. Verify the full request/response
lifecycle including SSE streaming and telemetry logging.

### 11.2 Prerequisites

- Running APISIX stack (Stage 4)
- `OPENCODE_ZEN_API_KEY` set in environment (from `.env`)
- `GATEWAY_API_KEY` set in environment (from `.env`)
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

| Commit | Content | Type |
|--------|---------|------|
| A+B (done) | `apisix.yaml`, `OPENCODE-INTEGRATION.md`, `TEST-PLAN.md` | fix |
| B2 | Revised `TEST-PLAN.md` (agentic gaps closed) | docs |
| C | `redact_lib.lua` + refactored `redact.lua` | refactor |
| D | Lua unit tests + runner (Stage 1) | test |
| E | Config validation tests (Stage 2) | test |
| F | Reconciler shell tests (Stage 3) | test |
| G | Podman stack integration tests (Stage 4) | test |
| H | CI hook verification (Stage 5) | test |
| I | End-to-end Zen API tests (Stage 6) | test |
| J | Makefile + coverage config | chore |

### 12.2 Makefile Integration

Update `Makefile` targets:

| Target | Action |
|--------|--------|
| `lint` | `bash -n` on all `.sh` files; YAML validation via Python |
| `type-check` | Lua syntax check via `resty -bl` in Podman |
| `test` | `tests/run_all.sh` (stages 1 through 5; skip 6 unless `OPENCODE_ZEN_API_KEY` set) |
| `check` | `lint` + `type-check` + `test` |
| `check-push` | `check` + stage 6 (if Zen key available) |

### 12.3 Coverage Config

Update `config/coverage_thresholds.yaml` to reflect the Lua and
shell test structure:

```yaml
unit:
  path: tests/lua
  min_coverage: 0
  source_path: plugins/custom
  runner: "tests/lua/run.sh"
  coverage: "false"

config:
  path: tests/config
  min_coverage: 0
  source_path: conf
  runner: "tests/config/run.sh"
  coverage: "false"

integration:
  path: tests/integration
  min_coverage: 0
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
