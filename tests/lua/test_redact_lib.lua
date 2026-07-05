local redact_lib = require("redact_lib")

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

local function assert_contains(haystack, needle, msg)
    if haystack and string.find(haystack, needle, 1, true) then
        pass = pass + 1
    elseif not needle then
        pass = pass + 1
    else
        fail = fail + 1
        io.stderr:write("[FAIL] " .. msg .. " expected to contain=[" .. tostring(needle) .. "] actual=[" .. tostring(haystack) .. "]\n")
    end
end

local function assert_not_contains(haystack, needle, msg)
    if haystack and not string.find(haystack, needle, 1, true) then
        pass = pass + 1
    else
        fail = fail + 1
        io.stderr:write("[FAIL] " .. msg .. " expected NOT to contain=[" .. tostring(needle) .. "] actual=[" .. tostring(haystack) .. "]\n")
    end
end

local PATTERNS_FILE = "/workspace/conf/redact-patterns.json"

local function luhn_tests()
    assert_eq(redact_lib.luhn_valid("4111111111111111"), true, "luhn[1] visa")
    assert_eq(redact_lib.luhn_valid("5500000000000004"), true, "luhn[2] mc")
    assert_eq(redact_lib.luhn_valid("4111111111111112"), false, "luhn[3] off-by-one")
    assert_eq(redact_lib.luhn_valid("1234567890123456"), false, "luhn[4] bad checksum")
    assert_eq(redact_lib.luhn_valid("4111 1111 1111 1111"), true, "luhn[5] spaces")
    assert_eq(redact_lib.luhn_valid("4111-1111-1111-1111"), true, "luhn[6] dashes")
    assert_eq(redact_lib.luhn_valid("abcd"), false, "luhn[7] non-numeric")
end

local function load_patterns_tests()
    do
        local data, dict_alt = redact_lib.load_patterns(PATTERNS_FILE)
        check(data ~= nil, "load[1] data non-nil")
        check(type(data) == "table", "load[1] data is table")
        local nregex = 0
        if data and data.regex then
            for _ in ipairs(data.regex) do nregex = nregex + 1 end
        end
        assert_eq(nregex, 6, "load[1] 6 regex entries")
        check(dict_alt ~= nil, "load[1] dict_alt non-nil")
    end

    do
        local data, err = redact_lib.load_patterns("/nonexistent/file.json")
        check(data == nil, "load[2] returns nil for missing file")
        check(err ~= nil, "load[2] returns error for missing file")
    end

    do
        local tmp = "/tmp/bad_patterns.json"
        local f = io.open(tmp, "w")
        f:write("{ this is not : valid json ]")
        f:close()
        local data, err = redact_lib.load_patterns(tmp)
        check(data == nil, "load[3] returns nil for bad JSON")
        check(err ~= nil, "load[3] returns error for bad JSON")
        os.remove(tmp)
        local still_there = io.open(tmp, "r")
        check(still_there == nil, "load[3] temp file cleaned up")
        if still_there then still_there:close() end
    end
end

local function fresh_state()
    return {}, {}
end

local function redact_tests()
    local patterns, dict_alt = redact_lib.load_patterns(PATTERNS_FILE)
    check(patterns ~= nil and dict_alt ~= nil, "redact: patterns loaded for tests")

    do
        local counters, token_map = fresh_state()
        local r = redact_lib.redact_text(
            "Contact john@example.com", patterns, dict_alt,
            counters, token_map, false)
        assert_contains(r, "[EMAIL_1]", "redact[1] email")
    end

    do
        local counters, token_map = fresh_state()
        local r = redact_lib.redact_text(
            "SSN: 123-45-6789", patterns, dict_alt,
            counters, token_map, false)
        assert_contains(r, "[SSN_1]", "redact[2] ssn")
    end

    do
        local counters, token_map = fresh_state()
        local r = redact_lib.redact_text(
            "Card: 4111111111111111", patterns, dict_alt,
            counters, token_map, false)
        assert_contains(r, "[CREDIT_CARD_1]", "redact[3] valid card")
    end

    do
        local counters, token_map = fresh_state()
        local input = "Card: 1234567890123456"
        local r = redact_lib.redact_text(input, patterns, dict_alt,
            counters, token_map, false)
        assert_eq(r, input, "redact[4] invalid luhn unchanged")
    end

    do
        local counters, token_map = fresh_state()
        local r = redact_lib.redact_text(
            "Key sk-C0kLBSzAOK7bYPDueOkR", patterns, dict_alt,
            counters, token_map, false)
        assert_contains(r, "[API_KEY_1]", "redact[5] api key")
    end

    do
        local counters, token_map = fresh_state()
        local r = redact_lib.redact_text(
            "Call +1-800-555-1234", patterns, dict_alt,
            counters, token_map, false)
        assert_contains(r, "[PHONE_1]", "redact[6] phone")
    end

    do
        local counters, token_map = fresh_state()
        local r = redact_lib.redact_text(
            "Token: eyJhbGci.eyJzdWI.sflKxwR", patterns, dict_alt,
            counters, token_map, false)
        assert_contains(r, "[JWT_1]", "redact[7] jwt")
    end

    do
        local counters, token_map = fresh_state()
        local r = redact_lib.redact_text(
            "Working at Acme Corporation", patterns, dict_alt,
            counters, token_map, false)
        assert_contains(r, "[DICTIONARY_1]", "redact[8] dictionary")
    end

    do
        local counters, token_map = fresh_state()
        local r = redact_lib.redact_text(
            "John Smith at john@example.com", patterns, dict_alt,
            counters, token_map, false)
        assert_contains(r, "[DICTIONARY_1]", "redact[9] dictionary multi")
        assert_contains(r, "[EMAIL_1]", "redact[9] email multi")
    end

    do
        local counters, token_map = fresh_state()
        local r = redact_lib.redact_text(
            "Hello world", patterns, dict_alt,
            counters, token_map, false)
        assert_eq(r, "Hello world", "redact[10] no PII unchanged")
    end

    do
        local counters, token_map = fresh_state()
        local r = redact_lib.redact_text(
            "", patterns, dict_alt,
            counters, token_map, false)
        assert_eq(r, "", "redact[11] empty input")
    end

    do
        local custom_patterns = {
            regex = {
                {kind = "ipv4", pattern = "\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b", luhn_check = false}
            },
            dictionary = {}
        }
        local counters, token_map = fresh_state()
        local r = redact_lib.redact_text(
            "IP: 192.168.1.1", custom_patterns, nil,
            counters, token_map, true)
        assert_contains(r, "[IPV4_1]", "redact[12] ipv4 flag on")
    end

    do
        local custom_patterns = {
            regex = {
                {kind = "ipv4", pattern = "\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b", luhn_check = false}
            },
            dictionary = {}
        }
        local counters, token_map = fresh_state()
        local input = "IP: 192.168.1.1"
        local r = redact_lib.redact_text(
            input, custom_patterns, nil,
            counters, token_map, false)
        assert_eq(r, input, "redact[13] ipv4 flag off unchanged")
    end
end

local function restore_tests()
    do
        local map = {}
        map["[EMAIL_1]"] = "john@example.com"
        local r = redact_lib.restore_with_key("[EMAIL_1]", map)
        assert_eq(r, "john@example.com", "restore[1] single token")
    end

    do
        local map = {}
        map["[EMAIL_1]"] = "john@example.com"
        map["[SSN_1]"] = "123-45-6789"
        local r = redact_lib.restore_with_key("[EMAIL_1] [SSN_1]", map)
        assert_contains(r, "john@example.com", "restore[2] email restored")
        assert_contains(r, "123-45-6789", "restore[2] ssn restored")
    end

    do
        local map = {}
        local r = redact_lib.restore_with_key("[UNKNOWN_1]", map)
        assert_eq(r, "[UNKNOWN_1]", "restore[3] unknown token unchanged")
    end

    do
        local map = {}
        local r = redact_lib.restore_with_key("", map)
        assert_eq(r, "", "restore[4] empty text")
    end
end

local function main()
    luhn_tests()
    load_patterns_tests()
    redact_tests()
    restore_tests()

    io.write(string.format("\n==== Lua unit tests: %d passed, %d failed ====\n", pass, fail))
    if fail > 0 then
        io.stderr:write(string.format("FAILED: %d test(s) failed\n", fail))
        os.exit(1)
    end
end

main()