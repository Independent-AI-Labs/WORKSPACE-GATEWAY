-- Drop friction telemetry columns from request_signals
ALTER TABLE llm_gateway.request_signals DROP COLUMN IF EXISTS rule_denials;
ALTER TABLE llm_gateway.request_signals DROP COLUMN IF EXISTS user_rejections;
ALTER TABLE llm_gateway.request_signals DROP COLUMN IF EXISTS guard_rules;
ALTER TABLE llm_gateway.request_signals DROP COLUMN IF EXISTS guard_blocks;
