WITH ranked AS (
    SELECT
        coalesce(nullIf(key_id,''), nullIf(api_key_id,''), 'unknown') AS client,
        toInt64(sum(total_tokens)) AS total_tok,
        round(sum(cost), 2) AS total_cost
    FROM llm_gateway.usage_log
    WHERE {{ time_filter('timestamp') }}
      AND coalesce(nullIf(key_id,''), nullIf(api_key_id,''), 'unknown') IN ({{ gf_str_multi('api_key') }})
      AND model IN ({{ gf_str_multi('model') }})
    GROUP BY client
    ORDER BY total_cost DESC
    LIMIT 100
)
SELECT
    concat(toString(row_number() OVER ()), '. ', client, ' - ', multiIf(total_tok >= 1000000000, concat(toString(round(total_tok / 1000000000, 2)), 'B'), total_tok >= 1000000, concat(toString(round(total_tok / 1000000, 2)), 'M'), total_tok >= 1000, concat(toString(round(total_tok / 1000, 2)), 'K'), toString(total_tok))) AS name_str,
    concat('$', toString(floor(round(total_cost * 100) / 100)), '.', leftPad(toString(round(total_cost * 100) % 100), 2, '0')) AS value_str,
    multiIf(
        row_number() OVER () = 1, '#C9A44C',
        row_number() OVER () = 2, '#A8A9AD',
        row_number() OVER () = 3, '#B07A3C',
        '#FFFFFF'
    ) AS Color
FROM ranked
LIMIT 3