WITH gated AS (SELECT model FROM llm_gateway.usage_log WHERE {{ time_filter('timestamp') }} AND model != '' GROUP BY model HAVING count() >= 100)
SELECT
    concat('$', toString(floor(round(cpc * 100) / 100)), '.', leftPad(toString(round(cpc * 100) % 100), 2, '0')) AS "Cost per Completed Response (avg)",
    concat(toString(round(tpc, 1)), 's') AS "Avg Time per Completed",
    multiIf(n >= 1000000000, concat(toString(round(n / 1000000000, 2)), 'B'), n >= 1000000, concat(toString(round(n / 1000000, 2)), 'M'), n >= 1000, concat(toString(round(n / 1000, 2)), 'K'), toString(n)) AS "Completed Responses"
FROM (
    SELECT
        sumIf(cost, aborted = 0) / nullIf(countIf(aborted = 0), 0) AS cpc,
        avgIf(duration_ms, aborted = 0 AND duration_ms > 0) / 1000 AS tpc,
        countIf(aborted = 0) AS n
    FROM llm_gateway.usage_log
    WHERE {{ time_filter('timestamp') }}
      AND coalesce(nullIf(key_id,''), nullIf(api_key_id,''), 'unknown') IN ({{ gf_str_multi('api_key') }})
      AND model IN ({{ gf_str_multi('model') }})
      AND model IN (SELECT model FROM gated)
)
