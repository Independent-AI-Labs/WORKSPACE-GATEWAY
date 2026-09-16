-- Cruncher: rejection-language matching core (REQ-USEFULNESS-TELEMETRY FR-4).
-- Pure stdlib Lua 5.1 / LuaJIT: no resty.*, no cjson, no io beyond dict
-- files + stdin/stdout, so it runs under plain luajit and unit tests.
--
-- Dual mode:
--   * Invoked with >= 4 args (en.txt phrases.txt vader-negative.txt
--     dict_version) it runs as a TSV filter over stdin (orchestrator mode).
--   * Required with no chunk varargs it acts as a library for tests.
--
-- Input row:  request_id \t model \t ts \t is_followup \t message(TSV-escaped)
-- Output row: request_id \t model \t ts \t is_followup \t parsed \t profane \t
--             profane_count \t [terms] \t frustrated \t frustration_count \t
--             [terms] \t signal_count \t signal_weight \t dict_version
-- Arrays use ClickHouse TabSeparated syntax: [elem,elem]. Every matched
-- occurrence appends one canonical dictionary entry (FR-4.4), so a term
-- appearing 15 times yields 15 entries and 15 counts: no caps.

local Cruncher = {}

-- ---------- string helpers ----------

local function read_dict_lines(path)
    local f = io.open(path, "r")
    if not f then return nil, "cruncher: cannot open " .. path end
    local lines = {}
    for line in f:lines() do
        line = line:gsub("\r$", "")
        line = line:gsub("’", "'")
        line = line:lower():gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" then lines[#lines + 1] = line end
    end
    f:close()
    return lines
end

local function deletes1(w)
    local out = {}
    for i = 1, #w do
        local v = w:sub(1, i - 1) .. w:sub(i + 1)
        if v ~= "" then out[#out + 1] = v end
    end
    return out
end

-- All two-character deletions (SymSpell delete-2 tier, used for len>=8
-- words where distance-2 confirmation is allowed).
local function deletes2(w)
    local out = {}
    local d1 = deletes1(w)
    for _, v in ipairs(d1) do
        for _, v2 in ipairs(deletes1(v)) do
            out[#out + 1] = v2
        end
    end
    return out
end

-- Bounded Levenshtein: returns edit distance if <= maxd, else nil.
local function lev_within(a, b, maxd)
    if a == b then return 0 end
    local la, lb = #a, #b
    if la > lb then a, b, la, lb = b, a, lb, la end
    if lb - la > maxd then return nil end
    local prev, cur = {}, {}
    for j = 0, lb do prev[j] = j end
    for i = 1, la do
        cur[0] = i
        local row_min = i
        local ca = a:byte(i)
        for j = 1, lb do
            local cost = (ca == b:byte(j)) and 0 or 1
            local v = prev[j] + 1
            local v2 = cur[j - 1] + 1
            if v2 < v then v = v2 end
            v2 = prev[j - 1] + cost
            if v2 < v then v = v2 end
            cur[j] = v
            if v < row_min then row_min = v end
        end
        if row_min > maxd then return nil end
        prev, cur = cur, prev
    end
    local d = prev[lb]
    if d <= maxd then return d end
    return nil
end

local function trigram_set(s)
    local t = {}
    s = " " .. s .. " "
    for i = 1, #s - 2 do t[s:sub(i, i + 2)] = true end
    return t
end

local function trigram_sim(sa, sb)
    local ta, tb = trigram_set(sa), trigram_set(sb)
    local inter, union = 0, 0
    for k in pairs(ta) do
        union = union + 1
        if tb[k] then inter = inter + 1 end
    end
    for k in pairs(tb) do
        if not ta[k] then union = union + 1 end
    end
    if union == 0 then return 0 end
    return inter / union
end

-- Fuzzy distance gates (token length): distance-1 matching on short tokens
-- collides with the most common English words (how~hoe, help~hell, list~lust,
-- that~twat, book~boob, tool~fool -- all distance 1), so fuzziness starts at
-- 5 chars and distance-2 at 9. Tokens present in the generated common-English
-- blocklist (google-10000 + VADER lexicon + tech supplement) never
-- fuzzy-match either (where~whore, parsing~pissing, batch~bitch, fetch~felch,
-- parse~arse, chunk~chink are the dominant false positives). Exact dictionary
-- hits are unaffected by the blocklist.
local function max_dist_for(n)
    if n >= 9 then return 2 end
    if n >= 5 then return 1 end
    return 0
end

-- ---------- dictionary loading ----------

local function build_word_set(st, lines, words, del1, del2)
    for _, w in ipairs(lines) do
        words[w] = true
        if #w >= 4 then
            for _, v in ipairs(deletes1(w)) do
                if not del1[v] then del1[v] = {} end
                del1[v][#del1[v] + 1] = w
            end
            if #w >= 8 and del2 then
                for _, v in ipairs(deletes2(w)) do
                    if not del2[v] then del2[v] = {} end
                    del2[v][#del2[v] + 1] = w
                end
            end
        end
    end
end

function Cruncher.load(prof_path, phrase_path, vader_path, blocklist_path)
    local st = {
        words = {}, del1 = {}, del2 = {},
        vader = {},
        common = {},
        phrases = {}, anchors = {},
    }

    local prof_lines, err = read_dict_lines(prof_path)
    if not prof_lines then return nil, err end
    build_word_set(st, prof_lines, st.words, st.del1, st.del2)

    if blocklist_path then
        local block_lines, blerr = read_dict_lines(blocklist_path)
        if not block_lines then return nil, blerr end
        for _, w in ipairs(block_lines) do
            st.common[w] = true
        end
    end

    local phrase_lines, perr = read_dict_lines(phrase_path)
    if not phrase_lines then return nil, perr end
    for _, p in ipairs(phrase_lines) do
        local words = {}
        for tok in p:gmatch("%S+") do words[#words + 1] = tok end
        if #words >= 2 then
            local anchor = words[1]
            for _, w in ipairs(words) do
                if #w > #anchor then anchor = w end
            end
            local idx = #st.phrases + 1
            st.phrases[idx] = {
                text = p, words = words, wc = #words,
                anchor = anchor, anchor_pos = {},
            }
            for k, w in ipairs(words) do
                if w == anchor then
                    st.phrases[idx].anchor_pos[#st.phrases[idx].anchor_pos + 1] = k
                end
            end
            if not st.anchors[anchor] then st.anchors[anchor] = {} end
            st.anchors[anchor][#st.anchors[anchor] + 1] = idx
        end
    end

    local vf, verr = io.open(vader_path, "r")
    if not vf then return nil, "cruncher: cannot open " .. vader_path end
    for line in vf:lines() do
        line = line:gsub("\r$", ""):gsub("’", "'"):lower()
        local w, val = line:match("^(%S+)%s+(-?%d+%.?%d*)%s*$")
        if w and val then
            local v = tonumber(val)
            if v and v < 0 then
                st.vader[w] = math.abs(v) / 4.0
            end
        end
    end
    vf:close()

    return st
end

-- ---------- matching ----------

local function match_word_generic(st, tok, words, del1, del2)
    if words[tok] then return tok end
    if #tok < 5 or st.common[tok] then return nil end
    local maxd = max_dist_for(#tok)
    if maxd == 0 then return nil end
    local best, bestd
    local seen = {}
    local function consider(cand)
        if cand == nil or seen[cand] then return end
        seen[cand] = true
        if cand == tok then best, bestd = cand, 0 return end
        local d = lev_within(tok, cand, maxd)
        if d and (not bestd or d < bestd or (d == bestd and cand < best)) then
            best, bestd = cand, d
        end
    end
    -- SymSpell tiers: delete-1 catches single edits, delete-2 (len>=8)
    -- catches two-edit combos (sub+del, 2xsub, ins+sub) that delete-1
    -- candidate generation can never surface.
    if del1[tok] then
        for _, c in ipairs(del1[tok]) do consider(c) end
    end
    if del2 and del2[tok] then
        for _, c in ipairs(del2[tok]) do consider(c) end
    end
    local d1s = deletes1(tok)
    for _, v in ipairs(d1s) do
        if words[v] then consider(v) end
        if del1[v] then
            for _, c in ipairs(del1[v]) do consider(c) end
        end
        if maxd == 2 then
            if del2 and del2[v] then
                for _, c in ipairs(del2[v]) do consider(c) end
            end
        end
    end
    if maxd == 2 then
        for _, v in ipairs(deletes2(tok)) do
            if words[v] then consider(v) end
            if del1[v] then
                for _, c in ipairs(del1[v]) do consider(c) end
            end
        end
    end
    return best
end

function Cruncher.match_profanity(st, tok)
    return match_word_generic(st, tok, st.words, st.del1, st.del2)
end

-- VADER tier is exact-only: fuzzy matching here turns routine vocabulary
-- into signal (e.g. "error" -> "errors"/"terror"). Profanity keeps the
-- fuzzy tiers (explicit requirement); VADER words carry fractional
-- weights and their typos are not worth the precision loss.
function Cruncher.match_vader(st, tok)
    if st.vader[tok] then return tok end
    return nil
end

function Cruncher.tokenize(msg)
    msg = msg:gsub("’", "'"):lower()
    local toks = {}
    for tok in msg:gmatch("[%a%d']+") do
        tok = tok:gsub("^'+", ""):gsub("'+$", "")
        if tok ~= "" then toks[#toks + 1] = tok end
    end
    return toks
end

-- Returns { profane, profane_terms, frustrated, frustration_terms,
--           vader_terms, signal_count, signal_weight }.
-- Dedup precedence (FR-4.5): profane tokens first; phrase spans containing
-- a profane token are dropped; VADER skips profane tokens and phrase spans.
function Cruncher.match_message(st, msg)
    local res = {
        profane = 0, profane_terms = {},
        frustrated = 0, frustration_terms = {},
        vader_terms = {}, signal_count = 0, signal_weight = 0.0,
    }
    if not msg or msg == "" then return res end
    local toks = Cruncher.tokenize(msg)

    local prof_at = {}
    for i, tok in ipairs(toks) do
        local w = Cruncher.match_profanity(st, tok)
        if w then
            prof_at[i] = w
            res.profane = 1
            res.profane_terms[#res.profane_terms + 1] = w
        end
    end

    local covered = {}
    for i, tok in ipairs(toks) do
        local plist = st.anchors[tok]
        if plist then
            for _, pi in ipairs(plist) do
                local ph = st.phrases[pi]
                for _, k in ipairs(ph.anchor_pos) do
                    local start = i - k + 1
                    local stop = start + ph.wc - 1
                    if start >= 1 and stop <= #toks then
                        local overlap = false
                        local span = {}
                        for j = start, stop do
                            span[#span + 1] = toks[j]
                            if prof_at[j] or covered[j] then overlap = true end
                        end
                        if not overlap then
                            local sim = trigram_sim(table.concat(span, " "), ph.text)
                            if sim >= 0.7 then
                                for j = start, stop do covered[j] = true end
                                res.frustrated = 1
                                res.frustration_terms[#res.frustration_terms + 1] = ph.text
                                break
                            end
                        end
                    end
                end
            end
        end
    end

    for i, tok in ipairs(toks) do
        if not prof_at[i] and not covered[i] then
            local vw = Cruncher.match_vader(st, tok)
            if vw then
                res.vader_terms[#res.vader_terms + 1] = vw
                if st.vader[vw] then res.signal_weight = res.signal_weight + st.vader[vw] end
            end
        end
    end

    res.signal_count = #res.profane_terms + #res.frustration_terms + #res.vader_terms
    res.signal_weight = res.signal_weight + #res.profane_terms + #res.frustration_terms
    return res
end

-- ---------- TSV filter (orchestrator mode) ----------

local function unescape_tsv(s)
    return (s:gsub("\\(.)", function(c)
        if c == "n" then return "\n"
        elseif c == "t" then return "\t"
        elseif c == "r" then return "\r"
        elseif c == "b" then return "\b"
        elseif c == "f" then return "\f"
        elseif c == "0" then return "\0"
        else return c end
    end))
end

local function escape_tsv(s)
    return (s:gsub("[\\\t\n\r]", function(c)
        if c == "\\" then return "\\\\"
        elseif c == "\t" then return "\\t"
        elseif c == "\n" then return "\\n"
        else return "\\r" end
    end))
end

-- ClickHouse TabSeparated Array(String) elements are single-quoted with
-- backslash escaping (['a','b']).
local function ch_escape_elem(s)
    return (s:gsub("[\\']", "\\%0"))
end

local function ch_array(terms)
    if #terms == 0 then return "[]" end
    local out = {}
    for _, t in ipairs(terms) do
        out[#out + 1] = "'" .. ch_escape_elem(t) .. "'"
    end
    return "[" .. table.concat(out, ",") .. "]"
end

local function round2(x)
    return math.floor(x * 100 + 0.5) / 100
end

-- Input: 9 TSV fields (message last: it may contain TSV-escaped tabs/newlines):
-- request_id, model, ts, is_followup, guard_blocks, guard_rules_csv,
-- user_rejections, rule_denials, message. Fields 5-8 are friction counts
-- computed by SQL in the orchestrator (SPEC-USEFULNESS-TELEMETRY §5.2);
-- guard_rules_csv is a plain comma-joined id list (TSV-safe: ClickHouse
-- output-escapes quotes, so SQL must not build the array literal) and is
-- re-encoded here into the ClickHouse array format via ch_array.
-- Output columns: ... signal_count, signal_weight, then the four friction
-- fields, then dict_version.
local function split9(line)
    local fields = {}
    local pos = 1
    for i = 1, 8 do
        local s, e = line:find("\t", pos, true)
        if not s then return nil end
        fields[i] = line:sub(pos, s - 1)
        pos = e + 1
    end
    fields[9] = line:sub(pos)
    return fields
end

function Cruncher.run_filter(st, dict_version, instream, outstream)
    instream = instream or io.stdin
    outstream = outstream or io.stdout
    for line in instream:lines() do
        if line ~= "" then
            local f = split9(line)
            if not f then
                io.stderr:write("cruncher: skipping malformed row\n")
            else
                local request_id, model, ts, is_followup = f[1], f[2], f[3], f[4]
                local msg = unescape_tsv(f[9])
                local parsed = (msg == "") and 0 or 1
                local r = Cruncher.match_message(st, msg)
                local rules = {}
                if f[6] ~= "" then
                    for id in f[6]:gmatch("[^,]+") do rules[#rules + 1] = id end
                end
                outstream:write(table.concat({
                    escape_tsv(request_id), escape_tsv(model), escape_tsv(ts),
                    is_followup, parsed,
                    r.profane, tostring(#r.profane_terms), ch_array(r.profane_terms),
                    r.frustrated, tostring(#r.frustration_terms), ch_array(r.frustration_terms),
                    tostring(r.signal_count), string.format("%.2f", round2(r.signal_weight)),
                    f[5], ch_array(rules), f[7], f[8],
                    escape_tsv(dict_version),
                }, "\t") .. "\n")
            end
        end
    end
end

-- Chunk-level varargs: present only when executed as a script.
-- argv: en.txt phrases.txt vader-negative.txt fuzzy-blocklist.txt dict_version
local args = { ... }
if #args >= 5 then
    local st, err = Cruncher.load(args[1], args[2], args[3], args[4])
    if not st then
        io.stderr:write((err or "cruncher: load failed") .. "\n")
        os.exit(1)
    end
    Cruncher.run_filter(st, args[5])
end

return Cruncher
