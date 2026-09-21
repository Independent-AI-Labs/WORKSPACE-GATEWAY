WITH gated AS (SELECT model FROM llm_gateway.usage_log WHERE {{ time_filter('timestamp') }} AND model != '' GROUP BY model HAVING count() >= 100),
ev AS (
    SELECT
        u.completion_tokens AS ct,
        u.aborted AS ab,
        s.user_rejections + s.rule_denials + s.guard_blocks AS rej,
        lagInFrame(ct, 1) OVER (PARTITION BY if(r.session_id != '', r.session_id, concat('k:', coalesce(nullIf(r.key_id,''), nullIf(r.api_key_id,''), 'unknown'))) ORDER BY r.timestamp, r.request_id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS prev_ct, lagInFrame(cost, 1) OVER (PARTITION BY if(r.session_id != '', r.session_id, concat('k:', coalesce(nullIf(r.key_id,''), nullIf(r.api_key_id,''), 'unknown'))) ORDER BY r.timestamp, r.request_id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS prev_cost,
        lagInFrame(ab, 1) OVER (PARTITION BY if(r.session_id != '', r.session_id, concat('k:', coalesce(nullIf(r.key_id,''), nullIf(r.api_key_id,''), 'unknown'))) ORDER BY r.timestamp, r.request_id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS prev_ab
    FROM llm_gateway.request_log r
    INNER JOIN llm_gateway.usage_log u ON u.request_id = r.request_id
    INNER JOIN llm_gateway.request_signals s ON s.request_id = r.request_id
    WHERE {{ time_filter('r.timestamp') }}
      AND r.request_id != ''
      AND coalesce(nullIf(r.key_id,''), nullIf(r.api_key_id,''), 'unknown') IN ({{ gf_str_multi('api_key') }})
      AND u.model IN ({{ gf_str_multi('model') }})
      AND u.model IN (SELECT model FROM gated)
),
agg AS (
    SELECT
        sum(if(aborted > 0, completion_tokens, 0)) AS wasted_tokens,
        sum(completion_tokens) AS total_tokens,
        round(sumIf(cost, aborted > 0), 2) AS wasted_cost
    FROM llm_gateway.usage_log
    WHERE {{ time_filter('timestamp') }}
      AND coalesce(nullIf(key_id,''), nullIf(api_key_id,''), 'unknown') IN ({{ gf_str_multi('api_key') }})
      AND model IN ({{ gf_str_multi('model') }})
      AND model IN (SELECT model FROM gated)
),
rejw AS (
    SELECT sumIf(prev_ct, rej > 0 AND prev_ab = 0) AS rej_wasted, sumIf(prev_cost, rej > 0 AND prev_ab = 0) AS rej_cost FROM ev
)
SELECT
    multiIf(wasted_tokens + rej_wasted >= 1000000000, concat(toString(round((wasted_tokens + rej_wasted) / 1000000000, 2)), 'B'),
            wasted_tokens + rej_wasted >= 1000000, concat(toString(round((wasted_tokens + rej_wasted) / 1000000, 2)), 'M'),
            wasted_tokens + rej_wasted >= 1000, concat(toString(round((wasted_tokens + rej_wasted) / 1000, 2)), 'K'),
            toString(wasted_tokens + rej_wasted)) AS "Wasted Tokens",
    concat(toString(round(100 * (wasted_tokens + rej_wasted) / nullIf(total_tokens, 0), 2)), '%') AS "Wasted % of Total",
    concat('$', toString(floor(round((wasted_cost + rej_cost) * 100) / 100)), '.', leftPad(toString(round((wasted_cost + rej_cost) * 100) % 100), 2, '0')) AS "Cost of Wasted Tokens"
FROM agg, rejw
