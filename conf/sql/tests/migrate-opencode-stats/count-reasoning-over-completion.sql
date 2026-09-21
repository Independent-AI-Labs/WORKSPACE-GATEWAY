-- Lua-convention invariant: completion_tokens >= reasoning_tokens.
SELECT countIf(reasoning_tokens > completion_tokens) FROM llm_gateway.usage_log
