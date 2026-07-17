local jwt = require("kimi_jwt")

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

local function b64url_encode(value)
    local b64 = ngx.encode_base64(value)
    return b64:gsub("%+", "-"):gsub("/", "_"):gsub("=", "")
end

local function make_jwt(payload)
    local cjson = require("cjson.safe")
    local header = b64url_encode('{"alg":"none"}')
    local body = b64url_encode(cjson.encode(payload))
    return header .. "." .. body .. "."
end

local function token_hash_tests()
    do
        local h = jwt.token_hash("")
        assert_eq(h, "", "hash[1] empty token")
    end
    do
        local h1 = jwt.token_hash("abc")
        local h2 = jwt.token_hash("abc")
        assert_eq(h1, h2, "hash[2] deterministic")
        assert_eq(#h1, 64, "hash[3] sha256 hex length")
    end
end

local function decode_claims_tests()
    do
        local claims = jwt.decode_claims("")
        check(type(claims) == "table", "decode[1] empty returns table")
    end
    do
        local token = make_jwt({ sub = "user-123", exp = 1752783600 })
        local claims = jwt.decode_claims(token)
        assert_eq(claims.sub, "user-123", "decode[2] sub")
        assert_eq(tonumber(claims.exp), 1752783600, "decode[3] exp")
    end
    do
        local token = make_jwt({})
        local claims = jwt.decode_claims(token)
        check(type(claims) == "table", "decode[4] empty payload")
        assert_eq(claims.sub, nil, "decode[5] missing sub nil")
    end
    do
        local claims = jwt.decode_claims("not.a.jwt")
        check(type(claims) == "table", "decode[6] malformed returns table")
    end
end

local function expires_at_tests()
    do
        local exp = jwt.expires_at("")
        assert_eq(exp, nil, "exp[1] empty nil")
    end
    do
        local token = make_jwt({ exp = 1752783600 })
        assert_eq(jwt.expires_at(token), 1752783600, "exp[2] returns exp")
    end
    do
        local token = make_jwt({})
        assert_eq(jwt.expires_at(token), nil, "exp[3] no exp nil")
    end
end

local function is_expiring_tests()
    do
        local token = make_jwt({ exp = ngx.time() + 60 })
        check(jwt.is_expiring(token, 300), "expiring[1] within threshold")
    end
    do
        local token = make_jwt({ exp = ngx.time() + 3600 })
        check(not jwt.is_expiring(token, 300), "expiring[2] outside threshold")
    end
    do
        local token = make_jwt({})
        check(not jwt.is_expiring(token, 300), "expiring[3] no exp false")
    end
end

local function subject_tests()
    do
        local token = make_jwt({ sub = "user-123" })
        assert_eq(jwt.subject(token), "user-123", "sub[1] returns sub")
    end
    do
        local token = make_jwt({ email = "a@example.com" })
        assert_eq(jwt.subject(token), "a@example.com", "sub[2] falls back to email")
    end
    do
        local token = make_jwt({ user_id = "u-1" })
        assert_eq(jwt.subject(token), "u-1", "sub[3] falls back to user_id")
    end
    do
        local token = make_jwt({})
        assert_eq(jwt.subject(token), nil, "sub[4] empty nil")
    end
end

local function main()
    token_hash_tests()
    decode_claims_tests()
    expires_at_tests()
    is_expiring_tests()
    subject_tests()

    io.write(string.format("\n==== Kimi JWT tests: %d passed, %d failed ====\n", pass, fail))
    if fail > 0 then
        io.stderr:write(string.format("FAILED: %d test(s) failed\n", fail))
        os.exit(1)
    end
end

main()
