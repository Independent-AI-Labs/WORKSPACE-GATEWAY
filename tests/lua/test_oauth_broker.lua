local broker = require("oauth_broker")

local first = broker.gateway_device_code("upstream-device-code")
local second = broker.gateway_device_code("upstream-device-code")
assert(first:match("^gw%-%x+$"), "gateway code must be prefixed and hashed")
assert(first ~= second, "gateway codes must remain request-attempt unique")

print("PASS: oauth broker tests")
