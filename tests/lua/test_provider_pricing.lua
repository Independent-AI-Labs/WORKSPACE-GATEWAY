local pricing = require("provider_pricing")

local pass = 0
local fail = 0
local function check(condition, message)
    if condition then
        pass = pass + 1
    else
        fail = fail + 1
        io.stderr:write("[FAIL] " .. message .. "\n")
    end
end

local provider = {
    model_source = {
        type = "models_dev_provider",
        provider = "openai",
        normalize = { strip_prefix = "openai/" },
    },
    pricing = {
        source = { type = "models_dev", provider = "openai" },
        missing_policy = "unknown",
    },
}
local models_dev = {
    openai = {
        models = {
            ["gpt-5"] = {
                cost = { input = 0.2, output = 1.2, cache_read = 0.02,
                    cache_write = 0.25, reasoning = 1.2 },
            },
        },
    },
}

local rates, source = pricing.resolve(provider, "openai/gpt-5", {}, models_dev)
check(rates.input == 0.2 and rates.output == 1.2, "models.dev rates resolved")
check(rates.cache_write == 0.25 and rates.reasoning == 1.2,
    "extended models.dev rates preserved")
check(source == "models_dev", "models.dev provenance preserved")

provider.pricing.overrides = { ["gpt-5"] = { input = 9.0 } }
rates, source = pricing.resolve(provider, "gpt-5", {}, models_dev)
check(rates.input == 9.0 and rates.output == 1.2, "override wins per field")
check(source == "provider_override", "override provenance preserved")

local unknown = { pricing = { source = { type = "unknown" }, missing_policy = "unknown" } }
rates = pricing.resolve(unknown, "local-model", {}, models_dev)
check(rates == nil, "unknown source does not invent zero pricing")

io.write(string.format("\n==== Provider pricing tests: %d passed, %d failed ====\n", pass, fail))
if fail > 0 then os.exit(1) end
