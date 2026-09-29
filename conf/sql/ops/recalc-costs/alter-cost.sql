-- recalc-costs.sh: one cost revalue per (provider, rate) tuple.
-- Rewrites the total and its five per-category components together, and
-- matches a row when any of them (or the provenance) is stale, so the
-- 000016 component columns are backfilled on the first pass even when the
-- total already equals the priced amount.
ALTER TABLE {{ DB }}.usage_log
UPDATE cost = {{ EXPR }}, cost_source = {{ NEW_SOURCE }},
    cost_input_uncached = {{ EXPR_INPUT }},
    cost_cached = {{ EXPR_CACHED }},
    cost_cache_write = {{ EXPR_CACHE_WRITE }},
    cost_output = {{ EXPR_OUTPUT }},
    cost_reasoning = {{ EXPR_REASONING }}
WHERE provider_id = {{ PID }}
  AND model IN ({{ MODELS }})
  AND cost_source IN ({{ SOURCE_SQL }})
  AND (
      abs(cost - ({{ EXPR }})) > {{ EPSILON }}
      OR cost_source != {{ NEW_SOURCE }}
      OR abs(cost_input_uncached - ({{ EXPR_INPUT }})) > {{ EPSILON }}
      OR abs(cost_cached - ({{ EXPR_CACHED }})) > {{ EPSILON }}
      OR abs(cost_cache_write - ({{ EXPR_CACHE_WRITE }})) > {{ EPSILON }}
      OR abs(cost_output - ({{ EXPR_OUTPUT }})) > {{ EPSILON }}
      OR abs(cost_reasoning - ({{ EXPR_REASONING }})) > {{ EPSILON }}
  )
SETTINGS mutations_sync = 1
