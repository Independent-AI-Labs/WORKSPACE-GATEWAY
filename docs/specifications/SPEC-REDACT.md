# SPEC-REDACT: PII Redaction Plugin Implementation

**Date:** 2026-07-17
**Status:** Active
**Type:** Specification
**Requirements:** [REQ-REDACT](../requirements/REQ-REDACT.md)

> Implements in-process PII detection and re-hydration for LLM relay routes.
> Detection logic lives in the pure library `redact_lib.lua` (unit-testable
> outside nginx); the APISIX plugin `redact.lua` owns phase wiring, the
> `redact_state` shared-dict pattern cache (60s TTL), and per-request ctx state.
> Key invariants: fail-closed by default, no cosocket I/O in `body_filter`,
> redaction tokens are fixed ASCII `[KIND_N]`. This spec covers the current
> implementation only; the v2 NER sidecar is a separate Draft specification.

---

**Cross-references:**
- [REQ-REDACT](../requirements/REQ-REDACT.md): requirements
- [`plugins/custom/redact.lua`](../../plugins/custom/redact.lua): plugin manifest, schema, phase handlers
- [`plugins/custom/redact_lib.lua`](../../plugins/custom/redact_lib.lua): `load_patterns`, `redact_text`, `restore_with_key`, `luhn_valid`
- [`conf/redact-patterns.json`](../../conf/redact-patterns.json): shipped regex + dictionary patterns
- [`tests/lua/test_redact_lib.lua`](../../tests/lua/test_redact_lib.lua): unit tests
- [`tests/config/test_patterns_json.sh`](../../tests/config/test_patterns_json.sh): patterns-file config test

---

## 1. Overview

The `redact` plugin scans chat-completion request bodies for PII, replaces
matches with `[KIND_N]` tokens, stashes the token map in the request ctx, and
restores originals in the buffered response body. All detection is in-process
via `ngx.re` PCRE bindings; no network calls occur on the hot path.

## 2. Architectural Principles

### 2.1 Plugin/library split

`redact.lua` (the APISIX plugin, priority 2500) contains only nginx-phase
logic. All string algorithms live in `redact_lib.lua` so they can be exercised
by `tests/lua/test_redact_lib.lua` without a running gateway.

### 2.2 Fail-closed default

`on_error` defaults to `closed`: pattern-load failure or request-body re-encode
failure returns 503 rather than leaking unredacted PII upstream.

### 2.3 Buffer-then-restore

Responses are buffered to EOF in `body_filter` and restored in one pass. This
is always correct because restoration operates on the complete concatenated
body; the trade-off is loss of per-token streaming UX in `buffer` mode.

### 2.4 Shared-dict pattern cache

Decoded patterns and the dictionary alternation are cached in the
`redact_state` shared dict with a 60-second TTL (`patterns`, `patterns_time`,
`dict_alt` keys). Reload happens on cache miss/expiry, not per-request mtime
checks.

## 3. System Diagram

```
 request          redact.lua (priority 2500)
 ------->  access: redact_state cache (60s) or redact_lib.load_patterns
                   redact_text over messages[] -> [KIND_N] tokens
                   stash ctx.redact_token_map; rewrite body
                 |
                 v
            upstream LLM
                 |
 <-------  header_filter: clear Content-Length, X-Redact-Active: 1
 response  body_filter: buffer to EOF -> restore_with_key -> single chunk
           log: ctx.redact_log = {active, token_count, stream}
```

## 4. Plugin Manifest & Schema

From `plugins/custom/redact.lua:7-35`:

| Property | Value |
|----------|-------|
| name | `redact` |
| version | 0.1 |
| priority | 2500 |

| Schema property | Type | Default | Notes |
|-----------------|------|---------|-------|
| `patterns_file` | string | `/etc/apisix/redact-patterns.json` | in-container path |
| `stream_mode` | enum(`reject`,`buffer`,`passthrough`) | `buffer` | see §8 |
| `on_error` | enum(`closed`,`open`) | `closed` | fail posture |
| `redact_ips` | boolean | `false` | enables latent `ipv4` kind |

The deployed schema has **no** `ner_sidecar_url` / `ner_timeout_ms` properties;
the NER sidecar is out of scope for this spec.

## 5. Patterns File Format

`conf/redact-patterns.json` ships 6 regex patterns and 2 dictionary groups:

| kind | luhn_check | Notes |
|------|-----------|-------|
| email | no | RFC-ish `\b[A-Z0-9._%+-]+@...` |
| ssn | no | `\d{3}-\d{2}-\d{4}` |
| credit_card | yes | `(?:\d[ -]*?){13,16}` + Luhn gate |
| api_key | no | `(?:sk|pk|key)-[A-Za-z0-9]{20,}` |
| phone | no | international/US shapes |
| jwt | no | `eyJ...eyJ...` three-segment |

Dictionary groups: `organization` (3 entries), `person_name` (2 entries).
There is no `ipv4` pattern in the shipped file; the `redact_ips` gate in
`redact_text` is latent.

`load_patterns` escapes dictionary entry metacharacters with a literal
backslash (`entry:gsub("([^%w%s])", "\\%1")`) and joins entries with `|` into
a single PCRE alternation.

## 6. Detection & Token Minting

`redact_lib.redact_text(text, patterns, dict_alt, counters, token_map, redact_ips)`:

1. For each regex pattern (skipping `ipv4` unless `redact_ips`), run
   `ngx.re.gsub(text, pattern, replace_cb, "ijo")`.
2. The callback returns the original match unchanged when `luhn_check` is set
   and `luhn_valid` fails; otherwise it increments `counters[KIND]`, mints
   `[KIND_N]`, records `token_map[token] = match_text`, and returns the token.
3. The dictionary alternation is applied last with kind `DICTIONARY`.
4. A `gsub` error on one pattern writes to stderr and continues with the next.

`luhn_valid` strips spaces/dashes, walks digits right-to-left doubling every
second digit, and accepts when the sum is divisible by 10.

## 7. Phase Behavior

### 7.1 access

- Resolve patterns from the `redact_state` cache (60s TTL) or reload via
  `redact_lib.load_patterns` and repopulate the cache.
- Fail-closed (503 `redact: patterns file not loaded`) or fail-open with an
  error log when patterns cannot be loaded.
- Read and JSON-parse the body; if unparseable or `messages` is absent, set
  `X-Redact-Error: non-chat-body` and pass through.
- If `stream: true` and `stream_mode == "reject"`, return 400
  `redact: streaming rejected`.
- Redact every string `content` and every `content[]` part with `text`.
- Re-encode with `cjson`; on failure return 503 (`closed`) or pass the
  original body through (`open`).
- Set `ctx.redact_token_map`, `ctx.redact_active` (count > 0),
  `ctx.redact_token_count`, `ctx.redact_stream`.

### 7.2 header_filter

When `ctx.redact_active`: clear `Content-Length` (nginx downgrades to chunked
transfer; do not set `Transfer-Encoding` manually) and set
`X-Redact-Active: 1`.

### 7.3 body_filter

- `passthrough` + streaming request: return immediately (tokens leak to the
  client; never the default).
- Otherwise accumulate `ctx.redact_buffer`, swallowing non-EOF chunks.
- On EOF: streaming bodies get a whole-buffer `restore_with_key`;
  non-streaming bodies are JSON-parsed and restored per
  `choices[].message.content` (whole-buffer fallback on parse failure).
- Emit the restored body as the final chunk and clear the buffer.

### 7.4 restore_with_key

Iterates the token map, escapes Lua pattern metacharacters in the token
(`token:gsub("([^%w])", "%%%1")`), escapes `%` in the original
(`original:gsub("%%", "%%%%")`), and applies `result:gsub(esc, safe_original)`.

### 7.5 log

Populates `ctx.redact_log = { active, token_count, stream }` for the
`http-logger` payload toward Vector/ClickHouse.

## 8. Streaming Mode Matrix

| `stream_mode` | Behavior |
|---------------|----------|
| `reject` | 400 immediately when `stream: true` |
| `buffer` (default) | SSE buffered to EOF; restored once; single chunk emitted |
| `passthrough` | Chunks forwarded unmodified; tokens reach the client |

## 9. Failure Modes

| Failure | `on_error=closed` | `on_error=open` |
|---------|-------------------|-----------------|
| Patterns file missing/invalid | 503 | pass through unredacted + error log |
| Non-chat body | passthrough + `X-Redact-Error` header | same |
| Body re-encode failure | 503 | pass original body through + error log |
| `ngx.re.gsub` error per pattern | log to stderr, skip pattern | same |
| Empty upstream body at EOF | emit empty body | same |

## 10. Edge Cases & Decisions

- Multi-modal `content[]`: only `text` parts are scanned; image URLs are not.
- Dictionary matching is exact (escaped alternation); "Acme Corp" does not
  match "Acme Corporation".
- Token counters are per request; token indices restart at 1 for each request.
- `ctx.redact_active` is false when no PII was found, so `header_filter`,
  `body_filter`, and `log` all no-op.

## 11. File Map

| File | Purpose | Key Changes |
|------|---------|-------------|
| `plugins/custom/redact.lua` | APISIX plugin: phases, schema, cache, ctx | shared-dict 60s pattern cache; `X-Redact-Error` header |
| `plugins/custom/redact_lib.lua` | Pure detection/restore library | gsub-callback replacement; Luhn; escaped restore |
| `conf/redact-patterns.json` | Shipped regex + dictionary patterns | 6 regex kinds, 2 dictionary groups |
| `tests/lua/test_redact_lib.lua` | Unit tests | redact/restore/Luhn round-trips |
| `tests/config/test_patterns_json.sh` | Config test | validates patterns file |

## 12. Implementation Status

| Component | Status | Evidence |
|-----------|--------|----------|
| Plugin phases (access/header_filter/body_filter/log) | Implemented | plugins/custom/redact.lua |
| Detection library + Luhn | Implemented | plugins/custom/redact_lib.lua |
| Shared-dict 60s pattern cache | Implemented | redact.lua:44-74 |
| Shipped patterns file | Implemented | conf/redact-patterns.json |
| Unit + config tests | Implemented | tests/lua/test_redact_lib.lua, tests/config/test_patterns_json.sh |
| NER sidecar (v2) | Not implemented | separate Draft spec; no schema fields present |
| `ipv4` pattern | Not shipped | gate exists in code; conf file has no ipv4 entry |
