-- recalc-costs.sh: one cost revalue per (provider, rate) tuple.
ALTER TABLE {{ DB }}.usage_log
UPDATE cost = {{ EXPR }}, cost_source = {{ NEW_SOURCE }}
WHERE provider_id = {{ PID }}
  AND model IN ({{ MODELS }})
  AND cost_source IN ({{ SOURCE_SQL }})
  AND (abs(cost - ({{ EXPR }})) > {{ EPSILON }} OR cost_source != {{ NEW_SOURCE }})
SETTINGS mutations_sync = 1
