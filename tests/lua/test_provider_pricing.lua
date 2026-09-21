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

local rates, source = pricing.resolve(provider, "openai/gpt-5", models_dev)
check(rates.input == 0.2 and rates.output == 1.2, "models.dev rates resolved")
check(rates.cache_write == 0.25 and rates.reasoning == 1.2,
    "extended models.dev rates preserved")
check(source == "models_dev", "models.dev provenance preserved")

-- A pricing.overrides entry is the whole price for that model: it replaces
-- the models.dev record, it is not merged field by field.
provider.pricing.overrides = { ["gpt-5"] = { input = 9.0 } }
rates, source = pricing.resolve(provider, "gpt-5", models_dev)
check(rates.input == 9.0, "override input wins")
check(rates.output == nil, "override replaces the models.dev record (no merge)")
check(source == "provider_override", "override provenance preserved")

provider.pricing.overrides = {
    ["gpt-5"] = { input = 9.0, output = 4.5, cache_read = 0.9 },
}
rates, source = pricing.resolve(provider, "gpt-5", models_dev)
check(rates.input == 9.0 and rates.output == 4.5 and rates.cache_read == 0.9,
    "complete override declares every rate")
check(rates.cache_write == nil, "override omits rates it does not declare")

-- A provider-declared alias bills at its target's price, even when the alias
-- id itself is unknown to the global registry.
provider.pricing.overrides = nil
provider.model_aliases = { ["gpt-5-alias"] = "gpt-5" }
rates, source = pricing.resolve(provider, "gpt-5-alias", models_dev)
check(rates and rates.input == 0.2, "provider alias resolves to target price")
check(source == "models_dev", "alias keeps the target provenance")

-- A model only in another models.dev namespace must NOT resolve: there is
-- no cross-provider scan.
local other = {
    pricing = { source = { type = "models_dev", provider = "openai" } },
}
local leaked = pricing.resolve(other, "gpt-5", {
    other_provider = { models = { ["gpt-5"] = { cost = { input = 7, output = 7 } } } },
})
check(leaked == nil, "cross-provider namespace does not resolve")

local unknown = { pricing = { source = { type = "unknown" } } }
rates = pricing.resolve(unknown, "local-model", models_dev)
check(rates == nil, "unknown source does not invent zero pricing")

io.write(string.format("\n==== Provider pricing tests: %d passed, %d failed ====\n", pass, fail))
if fail > 0 then os.exit(1) end
