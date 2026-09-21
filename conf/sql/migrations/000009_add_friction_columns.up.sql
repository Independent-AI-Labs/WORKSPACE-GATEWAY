-- Add friction telemetry columns to request_signals (REQ-USEFULNESS-TELEMETRY FR-8.4)
ALTER TABLE llm_gateway.request_signals ADD COLUMN IF NOT EXISTS guard_blocks UInt16 DEFAULT 0;
ALTER TABLE llm_gateway.request_signals ADD COLUMN IF NOT EXISTS guard_rules Array(String);
ALTER TABLE llm_gateway.request_signals ADD COLUMN IF NOT EXISTS user_rejections UInt16 DEFAULT 0;
ALTER TABLE llm_gateway.request_signals ADD COLUMN IF NOT EXISTS rule_denials UInt16 DEFAULT 0;
