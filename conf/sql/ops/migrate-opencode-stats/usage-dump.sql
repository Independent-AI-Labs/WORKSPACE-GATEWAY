-- Migrated usage rows for the dry-run diff (lib-opencode-stats-report.sh).
SELECT event_id, model, model_raw, provider_id,
       toString(prompt_tokens), toString(completion_tokens),
       toString(total_tokens), toString(cached_tokens),
       toString(cache_write_tokens), toString(reasoning_tokens),
       toString(cost), cost_source, toString(reported_cost),
       toString(timestamp),
       toString(duration_ms), toString(ttft_content_ms)
FROM {{ DB }}.usage_log
WHERE event_id LIKE '{{ PREFIX }}%'
FORMAT TabSeparated
