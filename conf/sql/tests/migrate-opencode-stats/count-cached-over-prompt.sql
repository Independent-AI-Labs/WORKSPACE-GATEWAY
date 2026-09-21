-- Lua-convention invariant: prompt_tokens >= cached_tokens.
SELECT countIf(cached_tokens > prompt_tokens) FROM llm_gateway.usage_log
