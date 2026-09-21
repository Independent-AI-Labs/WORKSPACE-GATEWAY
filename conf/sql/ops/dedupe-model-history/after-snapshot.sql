-- dedupe-model-history.sh: post-merge model/cost_source distribution.
SELECT model, cost_source, count(), sum(cost)
FROM {{ DB }}.usage_log
GROUP BY model, cost_source
ORDER BY count() DESC
FORMAT PrettyCompact
