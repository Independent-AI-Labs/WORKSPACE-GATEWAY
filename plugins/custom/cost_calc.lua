--plugins/custom/cost_calc.lua   (repo source path)
--Deployed to: /usr/local/apisix/apisix/plugins/cost_calc.lua  (flat, no custom/ subdir)
--Required as: require("apisix.plugins.cost_calc")
--Pure module, NOT an APISIX plugin. Required by sse-usage.lua in the log phase.
--No plugin = no schema, no priority, no phase bindings.
--
--READ-ONLY pricing consumer. The ONLY writer of pricing:* keys in the
--gateway-cache shared dict is provider_sync_pricing.lua (single-writer
--rule, enforced by tests/config/test_model_registry.sh). provider-sync warms
--the cache in plugin.init() and via POST /gateway/providers/sync; this module
--never fetches, never triggers a sync, and treats a missing key as a miss.
--
--Model identity comes from model_registry.lua (generated from
--conf/model-registry.yaml). All pricing lookups are keyed by the
--canonical model id; there is no local normalization logic here.
--
--Billed cost comes from exactly one place: the provider-scoped price the
--pricing writer published (provider `pricing.overrides`, else models.dev
--within the provider's declared namespace). An upstream-reported cost is
--NOT billed; sse-usage persists it separately as reported_cost metadata.
--
--Dependency strategy: APISIX/OpenResty-specific modules (apisix.core,
--cjson.safe) and the ngx global are deferred-required inside the functions
--that use them, NOT at module top level. This keeps compute_cost and
--resolve_cost (priced + unknown branches) loadable and runnable in
--plain LuaJIT without the nginx worker runtime, so the unit test suite
--(tests/config/test_cost_calc.sh) runs with zero dependency injection.

local model_registry = require("apisix.plugins.model_registry")

local M = {}

local SHARED_DICT = "gateway-cache"
local PRICING_KEY_PREFIX = "pricing:"

M.SOURCE_PROVIDER_OVERRIDE = "provider_override"
M.SOURCE_MODELS_DEV = "models_dev"
M.SOURCE_UNKNOWN = "unknown"

--Route identity -> gateway provider id. Single source for both the live
--sse-usage log path and the offline recalc (res/scripts/cost/recalc.lua).
M.ROUTE_PROVIDERS = {
    ["relay-opencode"] = "workspace-gw-opencode-go-api-key",
    ["relay-opencode-federated"] = "workspace-gw-opencode-go-virtual-key",
    ["relay-opencode-zen"] = "workspace-gw-opencode-zen-api-key",
    ["relay-openai"] = "workspace-gw-openai-device-oauth",
    ["relay-kimi"] = "workspace-gw-kimi-device-oauth",
    ["relay-kimi-v1"] = "workspace-gw-kimi-device-oauth",
    ["relay-kimi-federated"] = "workspace-gw-kimi-virtual-key",
    ["relay-kimi-federated-v1"] = "workspace-gw-kimi-virtual-key",
    ["relay-kimi-key"] = "workspace-gw-kimi-api-key",
    ["relay-kimi-key-v1"] = "workspace-gw-kimi-api-key",
    ["relay-zai-key"] = "workspace-gw-zai-api-key",
    ["relay-zai-key-v1"] = "workspace-gw-zai-api-key",
    ["relay-anthropic"] = "workspace-gw-anthropic-passthrough",
    ["relay-anthropic-device"] = "workspace-gw-anthropic-device-oauth",
    ["relay-alibaba-token-plan"] = "workspace-gw-alibaba-token-plan-passthrough",
    ["relay-alibaba-token-plan-cn"] = "workspace-gw-alibaba-token-plan-cn-passthrough",
    ["relay-llamafile"] = "workspace-gw-llamafile-no-auth",
}

--Legacy provider ids that named a gateway route -> canonical gateway id.
--Only gateway-proven ids are listed. opencode's own direct providers
--(openai, opencode, opencode-go, zai-coding-plan, amazon-bedrock,
--workspace-gateway) abstract different upstreams and are left untouched.
M.PROVIDER_ALIASES = {
    ["workspace-gw-kimi"] = "workspace-gw-kimi-device-oauth",
    ["workspace-gw-own"] = "workspace-gw-opencode-go-api-key",
    ["workspace-gw-private"] = "workspace-gw-opencode-go-virtual-key",
    ["workspace-gw-zen-own"] = "workspace-gw-opencode-zen-api-key",
    ["workspace-gw-openai-headless"] = "workspace-gw-openai-device-oauth",
    ["workspace-gw-llamafile"] = "workspace-gw-llamafile-no-auth",
}

--event_id is route_id .. "_" .. start_time_sec (conf/vector.toml).
function M.route_of(event_id)
    if not event_id or event_id == "" then return "" end
    return (event_id:gsub("_[0-9]+$", ""))
end

--Resolve a telemetry row's gateway provider. Explicit only: an id that is
--neither canonical nor a known alias, and a route with no mapping, stay
--empty. No other provider is consulted.
function M.resolve_provider(provider_id, event_id)
    local alias = M.PROVIDER_ALIASES[provider_id or ""]
    if alias then return alias end
    if provider_id and provider_id ~= "" then return provider_id end
    return M.ROUTE_PROVIDERS[M.route_of(event_id)] or ""
end

local function get_dict()
    if not ngx or not ngx.shared then return nil end
    return ngx.shared[SHARED_DICT]
end

local function get_core()
    return require("apisix.core")
end

function M.get_pricing(model_id, provider_id)
    local dict = get_dict()
    if not dict then
        return nil, "miss"
    end

    --Provider identity is mandatory: a model id under different providers
    --can carry different prices and must never collide. There is no
    --provider-agnostic (unscoped) price key.
    if not provider_id or provider_id == "" then
        return nil, "miss"
    end

    local key = model_registry.canonical(model_id)
    if key == "" then
        return nil, "miss"
    end

    local raw = dict:get(PRICING_KEY_PREFIX .. provider_id .. ":" .. key)
    if not raw then
        --provider-sync is the sole pricing writer and warms the cache in
        --plugin.init(). A missing key is a real miss: no price for this
        --provider/model, or the warmup has not finished. No retry, no sync.
        return nil, "miss"
    end

    local cjson = require("cjson.safe")
    local price = cjson.decode(raw)
    if type(price) ~= "table" or type(price.input) ~= "number" then
        return nil, "miss"
    end

    return price, "fresh"
end

function M.compute_cost(tokens, price)
    if not tokens or not price then return 0 end

    local pt = tonumber(tokens.pt) or 0
    local ct = tonumber(tokens.ct) or 0
    local cached = tonumber(tokens.cached) or 0
    local cache_write = tonumber(tokens.cache_write) or 0
    local reasoning = tonumber(tokens.reasoning) or 0

    local input_rate = tonumber(price.input) or 0
    local output_rate = tonumber(price.output) or 0
    --A cache rate must never make tokens free. models.dev omits the field for
    --most providers and publishes an explicit 0 for zai, so a nil OR a
    --non-positive cache rate is billed at the input rate (FR-3.3). The same
    --rule covers a reasoning rate the catalog omits: it bills at the output
    --rate rather than free. input_rate is 0 only for a genuinely free model.
    local function billable_rate(value, floor_rate)
        local rate = tonumber(value)
        if rate and rate > 0 then return rate end
        return floor_rate
    end
    local cache_read_rate = billable_rate(price.cache_read, input_rate)
    local cache_write_rate = billable_rate(price.cache_write, input_rate)
    local reasoning_rate = billable_rate(price.reasoning, output_rate)

    local input_uncached = pt - cached - cache_write
    if input_uncached < 0 then input_uncached = 0 end

    --reasoning_tokens is inclusive in completion_tokens for OpenAI/Anthropic.
    --If a provider reports more reasoning than completion, reasoning is a
    --separate dimension, not a subset: bill both rather than clamping output
    --to zero (which would discard the visible output).
    --ponytail: heuristic guard, add a per-provider inclusive flag if a
    --provider reports reasoning <= completion but non-inclusive.
    local output_non_reasoning = ct - reasoning
    if output_non_reasoning < 0 then output_non_reasoning = ct end

    local cost = input_uncached * input_rate / 1e6
               + output_non_reasoning * output_rate / 1e6
               + cached * cache_read_rate / 1e6
               + cache_write * cache_write_rate / 1e6
               + reasoning * reasoning_rate / 1e6

    return cost
end

--Billed cost only. The price record's own `pricing_source` is the single
--provenance value; provider_sync_pricing writes only `provider_override` or
--`models_dev`. A record carrying anything else is a writer contract
--violation: log it and refuse to bill rather than mislabel the row.
function M.resolve_cost(tokens, model_id, provider_id)
    local price = M.get_pricing(model_id, provider_id)
    if not price then
        return 0, M.SOURCE_UNKNOWN
    end

    local source = price.pricing_source
    if source == M.SOURCE_PROVIDER_OVERRIDE or source == M.SOURCE_MODELS_DEV then
        return M.compute_cost(tokens, price), source
    end
    get_core().log.error("cost_calc: price for '", model_id,
        "' under provider '", provider_id,
        "' has unrecognized pricing_source '", tostring(source),
        "'; refusing to bill")
    return 0, M.SOURCE_UNKNOWN
end

return M
