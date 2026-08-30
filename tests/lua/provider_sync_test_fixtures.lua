local cjson = require("cjson.safe")

local M = {}
M.captured_requests = {}
M.fake_models_dev = {
    kimi = {
        models = {
            ["kimi-k1"] = {
                name = "Kimi K1", reasoning = false, attachment = false,
                tool_call = true, limit = { context = 128000, output = 8192 },
                cost = { input = 1.0, output = 3.0, cache_read = 0.5, cache_write = 1.5 },
            },
            ["kimi-k1-vision"] = {
                name = "Kimi K1 Vision", reasoning = false, attachment = true,
                tool_call = true, limit = { context = 128000, output = 8192 },
                cost = { input = 2.0, output = 6.0 },
            },
        },
    },
    openai = {
        models = {
            ["gpt-5"] = {
                name = "GPT-5", reasoning = true, attachment = false,
                tool_call = true, limit = { context = 256000, output = 16384 },
                cost = { input = 5.0, output = 15.0 },
            },
        },
    },
    minimax = {
        models = {
            ["minimax-m3"] = {
                name = "MiniMax M3", reasoning = true, attachment = false,
                tool_call = true, limit = { context = 204800, output = 16384 },
                cost = { input = 0.2, output = 0.9 },
            },
        },
    },
}
M.fake_gateway_models = {
    data = {
        { id = "minimax-m3" }, { id = "deepseek-v4-flash-free" },
        { id = "glm-5.2" }, { id = "mimo-v2.5-free" },
    },
}

M.http = {
    new = function()
        return {
            set_timeout = function() end,
            request_uri = function(_, url, opts)
                table.insert(M.captured_requests, {
                    url = url, method = opts.method or "GET", headers = opts.headers or {},
                })
                local body = url:match("models%.dev")
                    and cjson.encode(M.fake_models_dev)
                    or cjson.encode(M.fake_gateway_models)
                return { status = 200, body = body }, nil
            end,
        }
    end,
}

return M
