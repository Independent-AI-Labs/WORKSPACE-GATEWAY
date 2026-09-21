-- Cost recalculation core (SPEC-COST-CALC).
--
-- Pure stdlib Lua 5.1 / LuaJIT: no resty.*, no cjson, no io beyond the
-- rate file + stdin/stdout, so it runs under plain luajit and in unit
-- tests. It reuses cost_calc.compute_cost and model_registry.canonical,
-- so a repair pass and the live request path share exactly one formula.
--
-- Dual mode:
--   * CLI (>= 1 arg): argv[1] is a rates TSV, argv[2] an optional epsilon.
--     Reads usage rows on stdin, writes one correction row per line for
--     rows whose recomputed cost differs by more than epsilon.
--   * Required with no varargs: exposes the pure functions for tests.
--
-- Rates TSV (one per line, tab-separated):
--   provider_id  model_id  input  output  cache_read  cache_write  reasoning
--   [source]        (source = provider_override | models_dev; default models_dev)
--
-- Usage rows (stdin, tab-separated):
--   event_id  request_id  timestamp  provider_id  model  prompt  completion
--   total  cached  cache_write  reasoning  cost_source  cost
--
-- Correction rows (stdout, unit-separator (\31) separated):
--   event_id  request_id  timestamp  new_cost  old_cost  old_source
--   provider_id  model  old_provider_id  canonical_model
--   input  output  cache_read  cache_write  reasoning  new_source
--
-- The unit separator (not a tab) keeps empty fields -- migrated rows carry
-- an empty request_id -- from being collapsed by the shell's readonly
-- IFS tab splitting. The trailing rate tuple lets the shell batch cost
-- corrections into one UPDATE per (provider, rate) group instead of one per
-- row; it is the same price record compute_cost used.
--
-- provider_id is the resolved gateway provider. When it differs from
-- old_provider_id the row is corrected even if new_cost equals old_cost
-- (provider_id-only backfill: an upstream row keeps its cost and source).
--
-- Safety invariants enforced here (the shell wrapper adds the rest):
--   * a row with no valid provider-scoped price is left untouched;
--   * prices without a positive input rate are ignored, so a malformed
--     catalog can never zero out a previously priced row;
--   * a provider is only ever resolved through the explicit alias/route
--     map (cost_calc.resolve_provider), with no other provider consulted;
--   * the upstream-reported cost is never consulted: billed cost is always
--     the provider-scoped price. reported_cost is a separate DB column and
--     is not touched by this tool.

local cost_calc = require("cost_calc")
local registry = require("model_registry")

local M = {}

local function split_tsv(line)
    local fields = {}
    local start = 1
    while true do
        local sep = line:find("\t", start, true)
        if not sep then
            fields[#fields + 1] = line:sub(start):gsub("\r$", "")
            break
        end
        fields[#fields + 1] = line:sub(start, sep - 1)
        start = sep + 1
    end
    return fields
end
M.split_tsv = split_tsv

-- Build a provider-scoped price map, mirroring cost_calc.get_pricing: the
-- key is provider_id .. ":" .. canonical_model_id and a missing provider is
-- a miss (never a provider-agnostic price).
function M.build_prices(lines)
    local prices = {}
    for _, line in ipairs(lines) do
        if line ~= "" then
            local f = split_tsv(line)
            local provider_id, model_id = f[1], f[2]
            local input = tonumber(f[3]) or 0
            local output = tonumber(f[4]) or 0
            local key = registry.canonical(model_id)
            -- Ignore rate rows the live path would treat as a miss: no
            -- provider, no canonical key, or no positive input rate (guards
            -- against a malformed catalog zeroing token costs).
            if provider_id and provider_id ~= "" and key ~= "" and input > 0 then
                -- Mirror provider_sync_pricing: a nil or non-positive cache
                -- rate is published at the input rate (never free), and a
                -- reasoning rate is left unset when absent so the output rate
                -- applies. The shell UPDATE reads this tuple directly, so the
                -- effective rates must be baked in here.
                local cache_read = tonumber(f[5]) or 0
                if cache_read <= 0 then cache_read = input end
                local cache_write = tonumber(f[6]) or 0
                if cache_write <= 0 then cache_write = input end
                local reasoning = tonumber(f[7]) or 0
                if reasoning <= 0 then reasoning = nil end
                local source = f[8]
                if source ~= "provider_override" and source ~= "models_dev" then
                    error("recalc: rate row " .. provider_id .. ":" .. key
                        .. " has unrecognized provenance '" .. tostring(source) .. "'")
                end
                prices[provider_id .. ":" .. key] = {
                    input = input,
                    output = output,
                    cache_read = cache_read,
                    cache_write = cache_write,
                    reasoning = reasoning,
                    source = source,
                }
            end
        end
    end
    return prices
end

function M.lookup(prices, provider_id, model_id)
    if not provider_id or provider_id == "" then return nil end
    local key = registry.canonical(model_id)
    if key == "" then return nil end
    return prices[provider_id .. ":" .. key]
end

local function tokens_of(row)
    return {
        pt = tonumber(row[6]) or 0,
        ct = tonumber(row[7]) or 0,
        cached = tonumber(row[9]) or 0,
        cache_write = tonumber(row[10]) or 0,
        reasoning = tonumber(row[11]) or 0,
    }
end

-- Resolve a row's gateway provider (explicit alias/route map only).
function M.resolve(row)
    return cost_calc.resolve_provider(row[4], row[1])
end

-- Return new_cost, resolved_provider, price when the row should be corrected,
-- else nil, resolved_provider, price. A nil new_cost with a changed provider
-- means provider_id-only backfill: cost and provenance stay put. price is the
-- provider-scoped rate record (nil when unpriced) for the shell's bulk UPDATE.
function M.decide(prices, row, epsilon)
    epsilon = epsilon or 1e-9
    local old_provider = row[4] or ""
    local provider = M.resolve(row)
    local provider_changed = provider ~= "" and provider ~= old_provider

    local price = nil
    local new_cost = nil
    if provider ~= "" then
        price = M.lookup(prices, provider, row[5])
        --Every row with a provider-scoped price is revalued, regardless of
        --its previous source: an upstream-reported cost is not billed.
        if price then
            local c = cost_calc.compute_cost(tokens_of(row), price)
            local old_cost = tonumber(row[13]) or 0
            local old_source = row[12] or ""
            --Provenance is part of the row: a priced row whose source still
            --names the wrong channel is corrected even when the amount
            --coincides, so the enum reflects where the price came from.
            if math.abs(c - old_cost) > epsilon or price.source ~= old_source then
                new_cost = c
            end
        end
    end

    if new_cost == nil and not provider_changed then return nil, provider, price end
    return new_cost, provider, price
end

local function run_cli(args)
    local rates_path = args[1]
    local epsilon = tonumber(args[2]) or 1e-9
    if not rates_path then
        io.stderr:write("recalc.lua: usage: luajit recalc.lua RATES.tsv [EPSILON]\n")
        os.exit(2)
    end

    local rate_file = assert(io.open(rates_path, "r"))
    local lines = {}
    for line in rate_file:lines() do lines[#lines + 1] = line end
    rate_file:close()
    local prices = M.build_prices(lines)

    for line in io.lines() do
        if line ~= "" then
            local row = split_tsv(line)
            if row[1] and row[1] ~= "" then
                local new_cost, provider, price = M.decide(prices, row, epsilon)
                local old_cost = row[13] or "0"
                local old_provider = row[4] or ""
                if new_cost or (provider ~= "" and provider ~= old_provider) then
                    -- Reuse the original cost text verbatim so a
                    -- provider_id-only backfill is byte-identical on cost and
                    -- the shell guard treats it as unchanged.
                    local cost_field = old_cost
                    if new_cost then
                        cost_field = string.format("%.17g", new_cost)
                    end
                    local canonical = registry.canonical(row[5] or "")
                    local pi = price and price.input or 0
                    local po = price and price.output or 0
                    local pcr = price and price.cache_read or 0
                    local pcw = price and price.cache_write or 0
                    -- Emit the effective reasoning rate the shell's UPDATE must
                    -- use: when the catalog has none, reasoning bills at the
                    -- output rate, exactly as compute_cost does.
                    local prr = (price and price.reasoning) or (price and price.output) or 0
                    local nsrc = (price and price.source) or "unknown"
                    io.write(string.format(
                        "%s\31%s\31%s\31%s\31%s\31%s\31%s\31%s\31%s\31%s\31%.17g\31%.17g\31%.17g\31%.17g\31%.17g\31%s\n",
                        row[1], row[2] or "", row[3] or "",
                        cost_field, old_cost,
                        row[12] or "", provider ~= "" and provider or old_provider,
                        row[5] or "", old_provider,
                        canonical, pi, po, pcr, pcw, prr, nsrc))
                end
            end
        end
    end
end

-- Only run the stdin/stdout CLI when this file is the main chunk (not when
-- required by the test suite, where arg[0] is the test script).
if arg and arg[0] and arg[0]:match("recalc%.lua$") and arg[1] then
    run_cli(arg)
end

return M
