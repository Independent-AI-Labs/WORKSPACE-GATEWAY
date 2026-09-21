-- Signals for a window, ordered for byte-identical idempotency comparison.
SELECT request_id, is_followup, parsed, profane, profane_count,
       arrayStringConcat(profane_terms, ','), frustrated, frustration_count,
       arrayStringConcat(frustration_terms, ','), signal_count, signal_weight,
       guard_blocks, arrayStringConcat(guard_rules, ','), user_rejections, rule_denials
FROM llm_gateway.request_signals
WHERE timestamp >= '{{ WT0 }}' AND timestamp < '{{ WT1 }}' AND request_id LIKE '{{ PREFIX }}%'
ORDER BY request_id FORMAT TSV
