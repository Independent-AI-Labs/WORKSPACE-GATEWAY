# Plugin Spec: PII Redaction - APISIX Custom Lua Plugin

**Document ID:** AMI-PROP-LLMGW-PLUGIN-REDACT-LUA-v2.0
**Status:** Draft
**Date:** 2026-07-05
**Parent:** `PROPOSAL-LLM-GATEWAY-v3.md`; inherits `PLUGIN-FOUNDATION.md`
**Companion:** `PLUGIN-REDACT-ENGINE.md` (optional NER sidecar, v2)

This document specifies the **pure Lua APISIX plugin** that performs PII detection
and anonymization in-process using `ngx.re` (PCRE C bindings) and a file-based
dictionary of sensitive string patterns. The PII Map is stashed in `ctx`
(per-request context). Re-hydration in `body_filter` uses local string substitution
(no cosocket allowed there). Zero sidecar calls on the hot path, all detection is
in-process, sub-millisecond.

v2 adds an optional NER sidecar (`PLUGIN-REDACT-ENGINE.md`) for named-entity
detection (Person/Org/Location), invoked off-thread via `ngx.timer.at`.

---

## 1. Architecture

```
                   APISIX custom Lua plugin (in-process, nginx worker)
                  +--------------------------------------------------+
                  | init:   load redact-patterns.json (regex + dict)  |
                  |         compile PCRE patterns via ngx.re           |
                  |         build dictionary alternation regex         |
                  |                                                   |
                  | access: scan message content with regex + dict     |
 request ------>  |   replace PII -> [KIND_N] redaction tokens             | -----> upstream LLM
                  |   stash PII Map in ctx (per-request)               |
                  |   rewrite request body                             |
                  |                                                   |
                  | header_filter: clear Content-Length                |
                  | body_filter:  buffer to EOF -> local gsub restore  |
 response <-----  |               from ctx PII Map                     | <----- upstream LLM
                  |                                                   |
                  | log: emit redact.* metrics                         |
                  +--------------------------------------------------+
                  | (v2) ngx.timer.at -> POST /ner to ner-engine      |
                  |       off-thread, best-effort NER enrichment       |
                  +--------------------------------------------------+
```

**Why pure Lua (no sidecar on hot path):**
- `ngx.re` uses PCRE C bindings, compiled native code, not interpreted Lua.
  Pattern matching is microseconds per kB.
- Dictionary matching via PCRE alternation (`org1|org2|...`), PCRE optimizes
  with an internal trie, O(n) in text length.
- Zero IPC overhead: no serialization, no network round-trip, no sidecar.
- The nginx worker yields at `ngx.re` find/gsub calls (cooperative multitasking),
  so other requests are not blocked.

---

## 2. Plugin Manifest

```lua
-- plugins/custom/redact.lua
local core = require("apisix.core")
local cjson = require("cjson.safe")
local ngx_re = require("ngx.re")

local plugin_name = "redact"

local _M = {
    version = 0.1,
    priority = 2500,          -- after auth (2599), before ai-proxy (2402)
    name = plugin_name,
}
```

---

## 3. Schema

```lua
_M.schema = {
    type = "object",
    properties = {
        patterns_file   = { type = "string", default = "/etc/apisix/redact-patterns.json" },
        stream_mode     = { type = "string", enum = { "reject", "buffer", "passthrough" },
                            default = "buffer" },
        on_error        = { type = "string", enum = { "closed", "open" }, default = "closed" },
        ner_sidecar_url = { type = "string", default = "" },     -- v2: empty = disabled
        ner_timeout_ms  = { type = "integer", default = 500 },
        redact_ips      = { type = "boolean", default = false },
    },
}

function _M.check_schema(conf)
    return core.schema.check(_M.schema, conf)
end
```

---

## 4. Patterns File Format

JSON file (cjson is bundled with APISIX). Loaded once at init, cached in a
module-level variable. Hot-reload by checking file mtime on each request (or
periodically via `ngx.timer.at`).

```json
{
  "regex": [
    { "kind": "email",       "pattern": "(?i)\\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}\\b" },
    { "kind": "ssn",         "pattern": "\\b\\d{3}-\\d{2}-\\d{4}\\b" },
    { "kind": "credit_card", "pattern": "\\b(?:\\d[ -]*?){13,16}\\b", "luhn_check": true },
    { "kind": "api_key",     "pattern": "(?i)\\b(?:sk|pk|key)-[A-Za-z0-9]{20,}\\b" },
    { "kind": "phone",       "pattern": "\\b\\+?\\d{1,3}?[-.\\s]?\\(?\\d{3}\\)?[-.\\s]?\\d{3,4}[-.\\s]?\\d{4}\\b" },
    { "kind": "jwt",         "pattern": "\\beyJ[A-Za-z0-9_-]+\\.eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\b" }
  ],
  "dictionary": [
    { "kind": "organization", "entries": ["Acme Corporation", "Project Phoenix", "Internal System X"] },
    { "kind": "person_name",  "entries": ["John Smith", "Jane Doe"] }
  ]
}
```

### 4.1 Loading and compilation

```lua
local loaded_patterns = nil
local loaded_mtime = 0
local dict_alternation = nil  -- compiled PCRE alternation for dictionary entries

local function load_patterns(filepath)
    local file, err = io.open(filepath, "r")
    if not file then return nil, err end
    local content = file:read("*a")
    file:close()
    local data = cjson.decode(content)
    if not data then return nil, "json decode failed" end

    -- Build dictionary alternation pattern: "Acme Corporation|Project Phoenix|..."
    if data.dictionary then
        local parts = {}
        for _, dict in ipairs(data.dictionary) do
            for _, entry in ipairs(dict.entries or {}) do
                -- Escape regex metacharacters in dictionary entries
                local escaped = entry:gsub("([^%w%s])", "%%%1")
                parts[#parts + 1] = escaped
            end
        end
        if #parts > 0 then
            dict_alternation = table.concat(parts, "|")
        end
    end
    return data
end

local function get_patterns(filepath)
    local attr = lfs.attributes(filepath, "modification")
    if not loaded_patterns or (attr and attr ~= loaded_mtime) then
        local data, err = load_patterns(filepath)
        if data then
            loaded_patterns = data
            loaded_mtime = attr or 0
        elseif err then
            core.log.error("redact: failed to load patterns: ", err)
        end
    end
    return loaded_patterns
end
```

---

## 5. PII Detection and Redaction token Minting

### 5.1 Luhn check (credit card false-positive suppression)

```lua
local function luhn_valid(card_number)
    card_number = card_number:gsub("[%s-]", "")
    local sum, parity = 0, 0
    for i = #card_number, 1, -1 do
        local digit = tonumber(card_number:sub(i, i))
        if not digit then return false end
        if parity % 2 == 1 then
            digit = digit * 2
            if digit > 9 then digit = digit - 9 end
        end
        sum = sum + digit
        parity = parity + 1
    end
    return sum % 10 == 0
end
```

### 5.2 Detection + replacement

```lua
local function redact_text(text, patterns, counters, pii_map, redact_ips)
    if not text or text == "" then return text end

    -- Regex patterns
    for _, p in ipairs(patterns.regex or {}) do
        if p.kind ~= "ipv4" or redact_ips then
            local it, err = ngx.re.gmatch(text, p.pattern, "ijo")
            if it then
                local positions = {}
                while true do
                    local m = it()
                    if not m then break end
                    local match_text = m[0]
                    -- Luhn check for credit cards
                    if p.luhn_check and not luhn_valid(match_text) then
                        -- false positive; skip
                    else
                        positions[#positions + 1] = { m[0].pos, #m[0], match_text }
                    end
                end
                -- Replace from right to left to preserve offsets
                for i = #positions, 1, -1 do
                    local pos = positions[i]
                    local kind_key = string.upper(p.kind)
                    counters[kind_key] = (counters[kind_key] or 0) + 1
                    local redaction token = string.format("[%s_%d]", kind_key, counters[kind_key])
                    pii_map[redaction token] = pos[3]
                    text = text:sub(1, pos[1] - 1) .. redaction token .. text:sub(pos[1] + pos[2])
                end
            end
        end
    end

    -- Dictionary alternation
    if dict_alternation then
        local it, err = ngx.re.gmatch(text, dict_alternation, "ijo")
        if it then
            local positions = {}
            while true do
                local m = it()
                if not m then break end
                positions[#positions + 1] = { m[0].pos, #m[0], m[0] }
            end
            for i = #positions, 1, -1 do
                local pos = positions[i]
                counters["DICTIONARY"] = (counters["DICTIONARY"] or 0) + 1
                local redaction token = string.format("[DICTIONARY_%d]", counters["DICTIONARY"])
                pii_map[redaction token] = pos[3]
                text = text:sub(1, pos[1] - 1) .. redaction token .. text:sub(pos[1] + pos[2])
            end
        end
    end

    return text
end
```

---

## 6. `access` Phase

```lua
function _M.access(conf, ctx)
    local patterns = get_patterns(conf.patterns_file)
    if not patterns then
        if conf.on_error == "closed" then
            return 503, { error = "redact: patterns file not loaded" }
        end
        core.log.error("redact: patterns not loaded; fail-open")
        return  -- fail open with warning
    end

    core.request.read_body(ctx)
    local body = core.request.get_body(ctx)
    if not body or body == "" then return end

    local ok, parsed = pcall(cjson.decode, body)
    if not ok or not parsed.messages then return end

    -- Streaming gate
    if parsed.stream and conf.stream_mode == "reject" then
        return 400, { error = "redact: streaming rejected; set stream_mode != reject" }
    end

    -- Redact each message's content
    local counters = {}
    local pii_map = {}
    for _, msg in ipairs(parsed.messages) do
        if type(msg.content) == "string" then
            msg.content = redact_text(msg.content, patterns, counters, pii_map, conf.redact_ips)
        elseif type(msg.content) == "table" then
            -- Multi-modal content parts
            for _, part in ipairs(msg.content) do
                if part.text then
                    part.text = redact_text(part.text, patterns, counters, pii_map, conf.redact_ips)
                end
            end
        end
    end

    -- Rewrite request body
    ngx.req.set_body_data(cjson.encode(parsed), #cjson.encode(parsed))

    -- Stash PII map in ctx
    local count = 0
    for _ in pairs(pii_map) do count = count + 1 end
    ctx.redact_key = pii_map
    ctx.redact_active = count > 0
    ctx.redact_placeholder_count = count
    ctx.redact_stream = parsed.stream and true or false

    -- v2: NER sidecar (off-thread, best-effort)
    if conf.ner_sidecar_url and conf.ner_sidecar_url ~= "" and count == 0 then
        -- Only call NER if regex found nothing (regex is fast; NER enriches)
        local req_id = core.request.header(ctx, "x-request-id") or ""
        ngx.timer.at(0, function(premature)
            if premature then return end
            local http = require("resty.http")
            local httpc = http.new()
            httpc:set_timeout(conf.ner_timeout_ms)
            -- Extract text for NER...
            local res, err = httpc:request_uri(conf.ner_sidecar_url .. "/ner", {
                method = "POST",
                body = cjson.encode({ text = body, correlation_id = req_id }),
                headers = { ["Content-Type"] = "application/json" },
            })
            if res and res.status == 200 then
                -- Merge NER entities into ctx.redact_key (if timer returns before body_filter)
                -- Best-effort: if body_filter already ran, NER results are lost (acceptable)
            end
            httpc:set_keepalive()
        end)
    end
end
```

---

## 7. `header_filter` Phase

```lua
function _M.header_filter(conf, ctx)
    if not ctx.redact_active then return end
    ngx.header.content_length = nil          -- force chunked transfer
    core.response.set_header(ctx, "X-Redact-Active", "1")
end
```

After clearing `Content-Length`, nginx auto-downgrades to
`Transfer-Encoding: chunked`. Do NOT set `Transfer-Encoding` manually.

---

## 8. `body_filter` Phase (Re-hydration)

Cosocket is NOT available here. Restoration is local string substitution.

```lua
local function restore_with_key(text, key)
    if not key or not text then return text end
    local result = text
    for fake, original in pairs(key) do
        local esc = fake:gsub("([^%w])", "%%%1")  -- escape regex metacharacters
        result = result:gsub(esc, original)
    end
    return result
end

function _M.body_filter(conf, ctx)
    if not ctx.redact_active then return end

    local chunk, eof = ngx.arg[1], ngx.arg[2]

    if conf.stream_mode == "passthrough" and ctx.redact_stream then
        return  -- emit unmodified; redaction tokens pass to client. DANGEROUS, default off.
    end

    -- Buffer-then-restore on EOF (default 'buffer' mode)
    ctx.redact_buffer = (ctx.redact_buffer or "") .. (chunk or "")
    if not eof then
        ngx.arg[1] = nil  -- swallow chunk
        return
    end

    local full_body = ctx.redact_buffer
    local new_body
    if ctx.redact_stream then
        -- SSE buffer: gsub the whole concatenated SSE block
        new_body = restore_with_key(full_body, ctx.redact_key)
    else
        -- Non-streaming JSON: parse, restore choices, re-encode
        local ok, parsed = pcall(cjson.decode, full_body)
        if ok and parsed.choices then
            for _, ch in ipairs(parsed.choices) do
                if ch.message and ch.message.content then
                    ch.message.content = restore_with_key(ch.message.content, ctx.redact_key)
                end
            end
            new_body = cjson.encode(parsed)
        else
            new_body = restore_with_key(full_body, ctx.redact_key)
        end
    end

    ngx.arg[1] = new_body
    ngx.arg[2] = true
    ctx.redact_buffer = nil
end
```

**Cross-chunk safety:** redaction tokens are fixed ASCII tokens (`[A-Z_0-9]+`). The
SSE buffer is gsub'd wholesale on EOF, which is always correct because the buffer
contains the full concatenated response.

---

## 9. `log` Phase

```lua
function _M.log(conf, ctx)
    if not ctx.redact_active then return end
    -- Set metadata for http-logger to serialize
    ctx.redact_log = {
        active = true,
        placeholder_count = ctx.redact_placeholder_count or 0,
        stream = ctx.redact_stream or false,
    }
end
```

These fields ride the `http-logger` payload to Vector -> ClickHouse. The billing
ledger schema (PROPOSAL §6.3) already has `redact_active`, `redact_placeholder_count`
columns.

---

## 10. Streaming Mode Decision Matrix

| `stream_mode` | Streaming request behavior |
|---------------|----------------------------|
| `reject` | 400 immediately if `stream:true` |
| `buffer` (default) | Forward `stream:true` upstream; buffer SSE to EOF in `body_filter`; restore once; flush as single chunk. Breaks per-token streaming UX (client sees whole response at once). |
| `passthrough` | Emit chunks unmodified; redaction tokens pass to client. Only acceptable if client is trusted/internal and re-hydrates. DANGEROUS, default off. |

**Future enhancement (v1.1):** Per-frame restore pattern, parse `data: {…}\n\n`
frames in the Lua buffer and restore per frame before emitting. Preserves
per-token streaming UX without breaking cross-chunk redaction tokens.

---

## 11. Failure Modes

| Failure | Detection | `on_error=closed` | `on_error=open` |
|---------|-----------|---------------------|------------------|
| Patterns file not found / invalid JSON | `get_patterns` returns nil | 503 | pass through unredacted |
| `ngx.re.gmatch` error | `it` returns nil, err | log + continue (regex skipped) | same |
| Request body not chat-shaped | `parsed.messages == nil` | passthrough (no redaction) | passthrough |
| `cjson.encode` fails on rewrite | pcall returns false | 502 | pass through original body |
| Empty response from upstream | `body == ""` on EOF | emit empty body | empty body |
| `body_filter` gsub fails | pcall wrap | log + emit raw (redaction tokens to client!) | same |

`on_error=closed` (default) is the production posture per AGENTS.md Rule 13.

---

## 12. Test Plan

- Unit: `redact_text` with email, SSN, card (valid + Luhn-fail), API key, phone, JWT.
- Unit: `restore_with_key` with redaction tokens containing `[]`, `%`, parens, must
  escape metacharacters and not double-substitute.
- Unit: Luhn check rejects 16-digit invoice IDs, accepts valid test card numbers.
- Unit: Dictionary matching, "Acme Corporation" matched, "Acme Corp" not matched
  (exact match only in v1).
- Unit: Round-trip: redact then restore = original text.
- Integration: end-to-end through APISIX; assert redaction tokens in upstream call,
  originals in client response.
- Stream-mode matrix: `reject` (400), `buffer` (defers to EOF, single emission),
  `passthrough` (redaction tokens pass through).
- Failure: invalid patterns file -> 503 (`closed`) / unredacted pass (`open`).
- Header: assert `Content-Length` cleared; assert chunked transfer encoding.
- No silent fallback: assert NO request proceeds without either redaction or
  an explicit `X-Redact-Error` header.

---

## 13. Open Questions

| Q | Resolution |
|---|------------|
| Patterns file format: JSON vs YAML | JSON (cjson bundled); YAML requires `lyaml` not guaranteed in APISIX image |
| Hot-reload mechanism | Check file mtime on each request (cheap `lfs.attributes` call); or periodic `ngx.timer.at` |
| Per-tenant dictionaries | v1: one global patterns file; v2: per-tenant file selected by `ctx.X-Tenant-ID` |
| PCRE alternation vs `lua-resty-aho-corasick` | PCRE alternation first (zero deps); switch to Aho-Corasick FFI if dictionary grows > 1000 entries and perf degrades |
| Multi-modal content (image URLs) | v1: redact `text` parts only; image URLs not scanned |

---

## 14. References

- `ngx.re` PCRE bindings: https://github.com/openresty/lua-nginx-module#ngxre
- PCRE trie optimization for alternation: https://www.pcre.org/original/doc/html/pcrepattern.html
- OpenResty cosocket ban in `body_filter`: https://github.com/openresty/lua-nginx-module#body_filter_by_lua
- APISIX plugin development: https://apisix.apache.org/docs/apisix/plugin-develop/
- Luhn algorithm: https://en.wikipedia.org/wiki/Luhn_algorithm
- `lua-resty-http`: https://github.com/ledgetech/lua-resty-http
- `cjson` (bundled with OpenResty): https://github.com/openresty/lua-cjson

---

**End of document.**
