INSERT INTO {{ DB }}.request_signals
(request_id, model, timestamp, is_followup, parsed, profane, profane_count,
 profane_terms, frustrated, frustration_count, frustration_terms,
 signal_count, signal_weight, guard_blocks, guard_rules, user_rejections,
 rule_denials, dict_version)
FORMAT TabSeparated
