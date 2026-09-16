-- Unit tests for res/scripts/usefulness/cruncher.lua
-- (REQ-USEFULNESS-TELEMETRY FR-4.x, FR-2.5: pure stdlib, requireable).
-- Fixtures are deterministic temp dictionaries; a final section sanity-loads
-- the real vendored dictionaries from the repo.

local Cruncher = require("cruncher")

local pass = 0
local fail = 0

local function check(cond, msg)
    if cond then
        pass = pass + 1
    else
        fail = fail + 1
        io.stderr:write("[FAIL] " .. msg .. "\n")
    end
end

local function assert_eq(actual, expected, msg)
    if type(expected) == "string" and type(actual) == "string" then
        check(actual == expected, msg .. " expected=[" .. expected .. "] actual=[" .. actual .. "]")
    else
        check(actual == expected, msg .. " expected=" .. tostring(expected) .. " actual=" .. tostring(actual))
    end
end

local function write_tmp(content)
    local path = os.tmpname()
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
    return path
end

local PROF = write_tmp(
    "shit\nfuck\ntesting\nabcdefgh\n")
local PHRASES = write_tmp(
    "not what i asked\ntry again\ndoesn't work\nuseless shit\n")
local VADER = write_tmp(
    "pathetic\t-2.7\nhorrible\t-2.5\nshit\t-3.0\nterrible\t-3.0\n")
local BLOCK = write_tmp(
    "how\nlist\nthat\nbook\ntests\nchose\nwhere\nparsing\nbatch\nfetch\nparse\nchunk\nassess\nhello\nshell\n")

local st, err = Cruncher.load(PROF, PHRASES, VADER, BLOCK)
check(st ~= nil, "load: dictionaries load (" .. tostring(err) .. ")")

-- ---------- tokenizer ----------

do
    local toks = Cruncher.tokenize("That's NOT what I asked??")
    local joined = table.concat(toks, "|")
    assert_eq(joined, "that's|not|what|i|asked", "tokenize[1] lowercase, apostrophes kept, punct stripped")
end

do
    local toks = Cruncher.tokenize("doesn’t work")
    assert_eq(table.concat(toks, "|"), "doesn't|work", "tokenize[2] curly apostrophe normalized")
end

-- ---------- fuzzy profanity (SymSpell delete-1 + bounded Levenshtein) ----------

do
    assert_eq(Cruncher.match_profanity(st, "shit"), "shit", "fuzzy[1] exact")
    assert_eq(Cruncher.match_profanity(st, "shiit"), "shit", "fuzzy[2] insertion typo")
    assert_eq(Cruncher.match_profanity(st, "shjt"), nil, "fuzzy[3] substitution typo under length gate")
    assert_eq(Cruncher.match_profanity(st, "shi"), nil, "fuzzy[4] deletion typo under length gate")
    assert_eq(Cruncher.match_profanity(st, "tasting"), "testing", "fuzzy[5] distance-1 on 7 chars")
    assert_eq(Cruncher.match_profanity(st, "tastimg"), nil, "fuzzy[6] distance-2 rejected below len 9")
    assert_eq(Cruncher.match_profanity(st, "abcxyefgh"), "abcdefgh", "fuzzy[7] distance-2 accepted at len>=9")
    assert_eq(Cruncher.match_profanity(st, "banana"), nil, "fuzzy[8] no match stays nil")
    -- Collision regression: distance-1 against common English words must
    -- never fire (generated blocklist: where~whore, parsing~pissing,
    -- batch~bitch, fetch~felch, parse~arse, chunk~chink, tests~teets,
    -- chose~chode, plus the sub-5-char tier how/list/that/book).
    assert_eq(Cruncher.match_profanity(st, "how"), nil, "fuzzy[9] 'how' is not 'hoe'")
    assert_eq(Cruncher.match_profanity(st, "list"), nil, "fuzzy[10] 'list' is not 'lust'")
    assert_eq(Cruncher.match_profanity(st, "that"), nil, "fuzzy[11] 'that' is not 'twat'")
    assert_eq(Cruncher.match_profanity(st, "book"), nil, "fuzzy[12] 'book' is not 'boob'")
    assert_eq(Cruncher.match_profanity(st, "tests"), nil, "fuzzy[13] 'tests' is not 'teets' (blocklist)")
    assert_eq(Cruncher.match_profanity(st, "chose"), nil, "fuzzy[14] 'chose' is not 'chode' (blocklist)")
    assert_eq(Cruncher.match_profanity(st, "where"), nil, "fuzzy[15] 'where' is not 'whore' (blocklist)")
    assert_eq(Cruncher.match_profanity(st, "parsing"), nil, "fuzzy[16] 'parsing' is not 'pissing' (blocklist)")
    assert_eq(Cruncher.match_profanity(st, "batch"), nil, "fuzzy[17] 'batch' is not 'bitch' (blocklist)")
    assert_eq(Cruncher.match_profanity(st, "fetch"), nil, "fuzzy[18] 'fetch' is not 'felch' (blocklist)")
    assert_eq(Cruncher.match_profanity(st, "chunk"), nil, "fuzzy[19] 'chunk' is not 'chink' (blocklist)")
    assert_eq(Cruncher.match_profanity(st, "shell"), nil, "fuzzy[20] 'shell' is not 'hell' (blocklist)")
    -- Exact dictionary hits are unaffected by the blocklist.
    assert_eq(Cruncher.match_profanity(st, "shit"), "shit", "fuzzy[21] exact unaffected by blocklist")
    -- Typo recall survives the tightened gates (single-char elongation at len 5).
    assert_eq(Cruncher.match_profanity(st, "fuuck"), "fuck", "fuzzy[22] single-char elongation at len 5")
end

-- ---------- phrase matching (anchor + trigram similarity) ----------

do
    local r = Cruncher.match_message(st, "that is not what i asked for")
    assert_eq(r.frustrated, 1, "phrase[1] flexible wording matches")
    assert_eq(r.frustration_terms[1], "not what i asked", "phrase[1] canonical phrase stored")

    r = Cruncher.match_message(st, "Try Again!!")
    assert_eq(r.frustrated, 1, "phrase[2] case+punctuation tolerant")

    r = Cruncher.match_message(st, "please try a different approach now")
    assert_eq(r.frustrated, 0, "phrase[3] near-miss below similarity floor")

    r = Cruncher.match_message(st, "try again, try again")
    assert_eq(#r.frustration_terms, 2, "phrase[4] non-overlapping repeats count per occurrence")
end

-- ---------- weighting, dedup precedence ----------

do
    -- FR-4.4: 15 occurrences weigh 15 (no caps).
    local msg = string.rep("fuck ", 15)
    local r = Cruncher.match_message(st, msg)
    assert_eq(#r.profane_terms, 15, "weight[1] 15 occurrences = 15 entries")
    assert_eq(r.signal_count, 15, "weight[2] signal_count 15")
    assert_eq(r.signal_weight, 15, "weight[3] weight 15.0 (1.0 each)")
end

do
    -- FR-4.5: profanity precedence; VADER duplicate skipped; phrase span
    -- containing a profane token dropped.
    local r = Cruncher.match_message(st, "shit")
    assert_eq(r.profane, 1, "dedup[1] profane flagged")
    assert_eq(#r.vader_terms, 0, "dedup[2] vader copy of profanity skipped")
    assert_eq(r.signal_count, 1, "dedup[3] counted once")
    assert_eq(r.signal_weight, 1, "dedup[4] weight 1.0 not 1.75")

    local r2 = Cruncher.match_message(st, "this useless shit again")
    assert_eq(r2.profane, 1, "dedup[5] profanity in span caught")
    assert_eq(#r2.frustration_terms, 0, "dedup[6] phrase span with profane token dropped")
end

do
    -- FR-5.7: VADER weight = |valence|/4, EXACT match only (fuzzy here turns
    -- routine vocabulary into signal: "error" -> "errors"/"terror").
    local r = Cruncher.match_message(st, "pathetic")
    assert_eq(#r.vader_terms, 1, "vader[1] matched")
    check(math.abs(r.signal_weight - 0.675) < 1e-9, "vader[2] weight |2.7|/4 = 0.675, got " .. tostring(r.signal_weight))
    assert_eq(Cruncher.match_vader(st, "pathetik"), nil, "vader[3] exact-only (no fuzzy)")
    assert_eq(Cruncher.match_vader(st, "terrors"), nil, "vader[4] fuzzy neighbors rejected")
end

do
    local r = Cruncher.match_message(st, "")
    assert_eq(r.signal_count, 0, "empty[1] no signals for empty message")
    local r2 = Cruncher.match_message(st, nil)
    assert_eq(r2.signal_count, 0, "empty[2] no signals for nil message")
end

-- ---------- TSV filter round-trip ----------

local function string_stream(s)
    return {
        lines = function(self)
            return s:gmatch("([^\n]*)\n?")
        end,
    }
end

do
    local out = {}
    local outstream = { write = function(self, chunk) out[#out + 1] = chunk end }
    -- 9-field input contract (SPEC §3.2): friction counts in fields 5-8;
   -- guard_rules arrives as plain csv (SQL never builds the array literal -
    -- ClickHouse TSV output escapes quotes); Lua re-encodes via ch_array.
    Cruncher.run_filter(st, "abc123", string_stream(
        'r1\tmodel-a\t2026-09-16 00:00:00.000\t1\t3\tsuppress-pipe,suppress-null\t1\t0\tthis is pathetic\\nand shit\n' ..
        'r2\tmodel-b\t2026-09-16 01:00:00.000\t0\t0\t\t0\t0\tlooks fine to me\n' ..
        'r3\tmodel-c\t2026-09-16 02:00:00.000\t1\t0\t\t0\t0\t\n'), outstream)
    local lines = table.concat(out)
    local n = 0
    for line in lines:gmatch("[^\n]+") do
        n = n + 1
        local f = {}
        for piece in line:gmatch("[^\t]+") do f[#f + 1] = piece end
        if n == 1 then
            assert_eq(#f, 18, "tsv[1] 18 fields out")
            assert_eq(f[1], "r1", "tsv[1] request_id")
            assert_eq(f[5], "1", "tsv[1] parsed")
            assert_eq(f[6], "1", "tsv[1] profane")
            assert_eq(f[7], "1", "tsv[1] profane_count")
            assert_eq(f[8], "['shit']", "tsv[1] profane_terms quoted array (CH TSV)")
            assert_eq(f[12], "2", "tsv[1] signal_count (shit + pathetic)")
            assert_eq(f[13], "1.68", "tsv[1] signal_weight 1 + 0.675 rounded")
            assert_eq(f[14], "3", "tsv[1] guard_blocks passthrough")
            assert_eq(f[15], "['suppress-pipe','suppress-null']", "tsv[1] csv re-encoded to CH array")
            assert_eq(f[16], "1", "tsv[1] user_rejections passthrough")
            assert_eq(f[17], "0", "tsv[1] rule_denials passthrough")
            assert_eq(f[18], "abc123", "tsv[1] dict_version passthrough")
        elseif n == 2 then
            assert_eq(f[6], "0", "tsv[2] clean message no profanity")
            assert_eq(f[12], "0", "tsv[2] signal_count 0")
            assert_eq(f[15], "[]", "tsv[2] empty csv to empty array")
        else
            assert_eq(f[5], "0", "tsv[3] empty message parsed=0")
        end
    end
    assert_eq(n, 3, "tsv[4] one output row per input row")
end

os.remove(PROF)
os.remove(PHRASES)
os.remove(VADER)
os.remove(BLOCK)

-- ---------- real vendored dictionaries sanity ----------

do
    -- Under tests/lua/run.sh the script path is /workspace/tests/lua/<file>;
    -- derive the repo root from it so the vendored dictionaries resolve.
    local repo = os.getenv("REPO_ROOT")
        or (arg and arg[0] and arg[0]:match("^(.*)/tests/lua/[^/]+$"))
        or "../.."
    local prof = repo .. "/conf/profanity/en.txt"
    local phrases = repo .. "/conf/profanity/frustration-phrases.txt"
    local vader = repo .. "/conf/profanity/vader-negative.txt"
    local block = repo .. "/conf/profanity/fuzzy-blocklist.txt"
    local real, rerr = Cruncher.load(prof, phrases, vader, block)
    check(real ~= nil, "vendored: dictionaries load from repo (" .. tostring(rerr) .. ")")
    if real then
        check(real.vader["pathetic"] ~= nil, "vendored: vader carries valence for pathetic")
        check(real.words["pathetic"] == nil, "vendored: profanity/VADER dedup applied at build")
        check(real.words["wrong"] ~= true and real.vader["wrong"] == nil,
              "vendored: coding-ambiguous stopword 'wrong' excluded")
        check(real.common["where"] == true, "vendored: blocklist covers 'where'")
        check(real.common["parsing"] == true, "vendored: blocklist covers 'parsing'")
        check(Cruncher.match_profanity(real, "where") == nil,
              "vendored: 'where' does not fuzzy-match 'whore'")
        check(Cruncher.match_profanity(real, "parsing") == nil,
              "vendored: 'parsing' does not fuzzy-match 'pissing'")
        check(Cruncher.match_profanity(real, "shiit") == "shit",
              "vendored: real typo 'shiit' still matches")
        local anchors = 0
        for _ in pairs(real.anchors) do anchors = anchors + 1 end
        check(anchors > 40, "vendored: phrase anchors indexed (" .. anchors .. ")")
    end
end

io.write(string.format("\n==== usefulness cruncher tests: %d passed, %d failed ====\n", pass, fail))
if fail > 0 then
    io.stderr:write(string.format("FAILED: %d test(s) failed\n", fail))
    os.exit(1)
end
