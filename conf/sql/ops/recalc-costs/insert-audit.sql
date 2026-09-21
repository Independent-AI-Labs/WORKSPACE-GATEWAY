INSERT INTO {{ DB }}.cost_recalc_audit
    (event_id, provider_id, new_provider_id, model, old_cost, new_cost, old_source, run_id)
    FORMAT TabSeparated
