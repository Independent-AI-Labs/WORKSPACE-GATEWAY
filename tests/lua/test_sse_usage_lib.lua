local sse_lib = require("sse_usage_lib")

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

local function buffer_chunk_tests()
    do
        local complete, remainder = sse_lib.buffer_chunk(nil, "data: hello\n")
        assert_eq(complete, "data: hello\n", "buffer[1] simple line")
        assert_eq(remainder, "", "buffer[1] no remainder")
    end

    do
        local complete, remainder = sse_lib.buffer_chunk("data: partial", " world\n")
        assert_eq(complete, "data: partial world\n", "buffer[2] joined across chunks")
        assert_eq(remainder, "", "buffer[2] no remainder")
    end

    do
        local complete, remainder = sse_lib.buffer_chunk(nil, "data: no newline")
        assert_eq(complete, "", "buffer[3] no complete line")
        assert_eq(remainder, "data: no newline", "buffer[3] remainder kept")
    end

    do
        local complete, remainder = sse_lib.buffer_chunk("data: line1\npartial", "data: line2\n")
        assert_eq(complete, "data: line1\npartialdata: line2\n", "buffer[4] two lines joined")
        assert_eq(remainder, "", "buffer[4] no remainder")
    end

    do
        local complete, remainder = sse_lib.buffer_chunk(nil, "")
        assert_eq(complete, "", "buffer[5] empty chunk")
        assert_eq(remainder, "", "buffer[5] no remainder")
    end

    do
        local complete, remainder = sse_lib.buffer_chunk("keep", nil)
        assert_eq(complete, "", "buffer[6] nil chunk")
        assert_eq(remainder, "keep", "buffer[6] existing preserved")
    end
end

local function scan_sse_tests()
    do
        local usage, model, done, cost, reasoning_text = sse_lib.scan_sse_for_usage(
            'data: {"choices":[{"delta":{"content":"hi"}}],"usage":null}\n')
        check(usage == nil, "scan[1] null usage returns nil")
    end

    do
        local usage, model, done, cost, reasoning_text = sse_lib.scan_sse_for_usage(
            'data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15},"model":"minimax-m3"}\n')
        check(usage ~= nil, "scan[2] usage found")
        if usage then
            assert_eq(usage.prompt_tokens, 10, "scan[2] prompt_tokens")
            assert_eq(usage.completion_tokens, 5, "scan[2] completion_tokens")
            assert_eq(usage.total_tokens, 15, "scan[2] total_tokens")
        end
        assert_eq(model, "minimax-m3", "scan[2] model")
    end

    do
        local usage, model, done, cost, reasoning_text = sse_lib.scan_sse_for_usage("data: [DONE]\n")
        check(usage == nil, "scan[3] DONE returns nil")
        check(done == true, "scan[3] done flag set")
    end

    do
        local usage, model, done, cost, reasoning_text = sse_lib.scan_sse_for_usage(
            'data: {"choices":[{"delta":{"content":"a"}}],"usage":null}\n' ..
            'data: {"choices":[{"delta":{"content":"b"}}],"usage":null}\n' ..
            'data: {"choices":[],"usage":{"prompt_tokens":20,"completion_tokens":10,"total_tokens":30},"model":"gpt-5"}\n' ..
            'data: [DONE]\n')
        check(usage ~= nil, "scan[4] usage found in multi-line")
        if usage then
            assert_eq(usage.total_tokens, 30, "scan[4] total_tokens")
        end
        assert_eq(model, "gpt-5", "scan[4] model")
        check(done == true, "scan[4] done flag set")
    end

    do
        local usage, model, done, cost, reasoning_text = sse_lib.scan_sse_for_usage("")
        check(usage == nil, "scan[5] empty string returns nil")
    end

    do
        local usage, model, done, cost, reasoning_text = sse_lib.scan_sse_for_usage("event: ping\ndata: not json\n")
        check(usage == nil, "scan[6] non-data lines ignored")
    end

    do
        local usage, model, done, cost, reasoning_text = sse_lib.scan_sse_for_usage("data: {bad json}\n")
        check(usage == nil, "scan[7] bad json returns nil")
    end

    do
        local usage, model, done, cost, reasoning_text = sse_lib.scan_sse_for_usage(
            'data: {"choices":[{"delta":{"reasoning_content":"Therefore,"}}],"usage":null}\n' ..
            'data: {"choices":[{"delta":{"reasoning_content":" we conclude"}}],"usage":null}\n' ..
            'data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15,"reasoning_tokens":3},"model":"glm-5.2"}\n')
        check(usage ~= nil, "scan[8] reasoning usage found")
        assert_eq(usage.reasoning_tokens, 3, "scan[8] reasoning_tokens")
        assert_eq(reasoning_text, "Therefore, we conclude", "scan[8] reasoning_text accumulated")
    end

    do
        local usage, model, done, cost, reasoning_text = sse_lib.scan_sse_for_usage(
            'data: {"choices":[{"delta":{"reasoning_content":"\xE4\xBD\xA0\xE5\xA5\xBD"}}],"usage":null}\n' ..
            'data: {"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":3,"total_tokens":8},"model":"deepseek-v4"}\n')
        check(usage ~= nil, "scan[9] CJK reasoning found")
        assert_eq(reasoning_text, "\xE4\xBD\xA0\xE5\xA5\xBD", "scan[9] CJK reasoning_text")
    end
end

local function parse_json_usage_tests()
    do
        local usage, model = sse_lib.parse_json_usage(
            '{"model":"minimax-m3","choices":[{"message":{"content":"hi"}}],"usage":{"prompt_tokens":5,"completion_tokens":3,"total_tokens":8}}')
        check(usage ~= nil, "json[1] usage found")
        if usage then
            assert_eq(usage.prompt_tokens, 5, "json[1] prompt_tokens")
            assert_eq(usage.total_tokens, 8, "json[1] total_tokens")
        end
        assert_eq(model, "minimax-m3", "json[1] model")
    end

    do
        local usage = sse_lib.parse_json_usage('{"error":"bad request"}')
        check(usage == nil, "json[2] no usage field returns nil")
    end

    do
        local usage = sse_lib.parse_json_usage("not json at all")
        check(usage == nil, "json[3] invalid json returns nil")
    end

    do
        local usage = sse_lib.parse_json_usage("")
        check(usage == nil, "json[4] empty string returns nil")
    end

    do
        local usage = sse_lib.parse_json_usage(nil)
        check(usage == nil, "json[5] nil returns nil")
    end
end

local function extract_tokens_tests()
    do
        local pt, ct, tt, cached, reasoning = sse_lib.extract_tokens(
            {prompt_tokens = 100, completion_tokens = 50, total_tokens = 150})
        assert_eq(pt, 100, "tokens[1] prompt")
        assert_eq(ct, 50, "tokens[1] completion")
        assert_eq(tt, 150, "tokens[1] total")
        assert_eq(cached, 0, "tokens[1] cached")
        assert_eq(reasoning, 0, "tokens[1] reasoning")
    end

    do
        local pt, ct, tt, cached, reasoning = sse_lib.extract_tokens(nil)
        assert_eq(pt, 0, "tokens[2] nil prompt")
        assert_eq(ct, 0, "tokens[2] nil completion")
        assert_eq(tt, 0, "tokens[2] nil total")
        assert_eq(cached, 0, "tokens[2] cached")
        assert_eq(reasoning, 0, "tokens[2] reasoning")
    end

    do
        local pt, ct, tt, cached, reasoning = sse_lib.extract_tokens({})
        assert_eq(pt, 0, "tokens[3] empty prompt")
        assert_eq(ct, 0, "tokens[3] empty completion")
        assert_eq(tt, 0, "tokens[3] empty total")
        assert_eq(cached, 0, "tokens[3] cached")
        assert_eq(reasoning, 0, "tokens[3] reasoning")
    end

    do
        local pt, ct, tt, cached, reasoning = sse_lib.extract_tokens(
            {prompt_tokens = "42", completion_tokens = "17", total_tokens = "59"})
        assert_eq(pt, 42, "tokens[4] string prompt")
        assert_eq(ct, 17, "tokens[4] string completion")
        assert_eq(tt, 59, "tokens[4] string total")
        assert_eq(cached, 0, "tokens[4] cached")
        assert_eq(reasoning, 0, "tokens[4] reasoning")
    end

    do
        local pt, ct, tt, cached, reasoning = sse_lib.extract_tokens(
            {prompt_tokens = 10, completion_tokens = 20, total_tokens = 30,
             cached_tokens = 5, reasoning_tokens = 3})
        assert_eq(cached, 5, "tokens[5] cached from top-level")
        assert_eq(reasoning, 3, "tokens[5] reasoning from top-level")
    end

    do
        local pt, ct, tt, cached, reasoning = sse_lib.extract_tokens(
            {prompt_tokens = 10, completion_tokens = 20, total_tokens = 30,
             prompt_tokens_details = {cached_tokens = 7}})
        assert_eq(cached, 7, "tokens[6] cached from details")
    end

    do
        local pt, ct, tt, cached, reasoning = sse_lib.extract_tokens(
            {prompt_tokens = 10, completion_tokens = 20, total_tokens = 30,
             completion_tokens_details = {reasoning_tokens = 4}})
        assert_eq(reasoning, 4, "tokens[7] reasoning from details")
    end

    do
        local pt, ct, tt, cached, reasoning = sse_lib.extract_tokens(
            {prompt_tokens = 10, completion_tokens = 20, total_tokens = 30},
            "Therefore, we conclude the answer is 42")
        assert_eq(reasoning, 10, "tokens[8] reasoning from text fallback")
    end
end

local function count_tokens_tests()
    do
        local n = sse_lib.count_tokens("")
        assert_eq(n, 0, "count[1] empty string")
    end

    do
        local n = sse_lib.count_tokens(nil)
        assert_eq(n, 0, "count[2] nil")
    end

    do
        local n = sse_lib.count_tokens("Hello world")
        assert_eq(n, 3, "count[3] ASCII: ceil(11/4)=3")
    end

    do
        local n = sse_lib.count_tokens("aaaaaaaaaaaaaaaaaaaa")
        assert_eq(n, 5, "count[4] ASCII: ceil(20/4)=5")
    end

    do
        --CJK chars: 6 bytes (3 bytes each), ceil(6/2)=3
        local n = sse_lib.count_tokens("\xE4\xBD\xA0\xE5\xA5\xBD")
        assert_eq(n, 3, "count[5] CJK: ceil(6/2)=3")
    end

    do
        --4 CJK chars = 12 bytes + 5 ASCII bytes
        local n = sse_lib.count_tokens("\xE4\xBD\xA0\xE5\xA5\xBD\xE4\xB8\x96\xE7\x95\x8C hello")
        --ASCII: 6 bytes (space+h+e+l+l+o), ceil(6/4)=2
        --CJK: 12 bytes, ceil(12/2)=6
        --Total: 8
        assert_eq(n, 8, "count[6] mixed CJK+ASCII: ceil(6/4)+ceil(12/2)=2+6=8")
    end
end

local function main()
    buffer_chunk_tests()
    scan_sse_tests()
    parse_json_usage_tests()
    extract_tokens_tests()
    count_tokens_tests()

    io.write(string.format("\n==== SSE usage lib tests: %d passed, %d failed ====\n", pass, fail))
    if fail > 0 then
        io.stderr:write(string.format("FAILED: %d test(s) failed\n", fail))
        os.exit(1)
    end
end

main()
