WITH totals AS (
    SELECT
        toInt64(sum(total_tokens)) as total_tok,
        toInt64(sum(prompt_tokens - cached_tokens)) as input_tok,
        toInt64(sum(cached_tokens)) as cached_tok,
        toInt64(sum(completion_tokens - reasoning_tokens)) as output_tok,
        toInt64(sum(reasoning_tokens)) as reasoning_tok,
        sum(cost) as total_cost
    FROM llm_gateway.usage_log
    WHERE {{ time_filter('timestamp') }} AND coalesce(nullIf(key_id,''), nullIf(api_key_id,''), 'unknown') IN ({{ gf_str_multi('api_key') }}) AND model IN ({{ gf_str_multi('model') }})
),
runrate AS (
    SELECT
        total_tok, input_tok, cached_tok, output_tok, reasoning_tok, total_cost,
        greatest(dateDiff('second', $__fromTime, $__toTime) / 86400, 1) as elapsed_days, -- noqa: LXR
        toDayOfMonth(toLastDayOfMonth(toDate($__toTime))) as days_in_month -- noqa: LXR
    FROM totals
),
avgs AS (
    SELECT
        total_tok, input_tok, cached_tok, output_tok, reasoning_tok, total_cost,
        round(total_tok / elapsed_days * days_in_month) as month_tok,
        round(total_tok / elapsed_days * 7) as week_tok,
        round(total_tok / elapsed_days) as day_tok,
        round(total_cost / elapsed_days * days_in_month, 2) as month_cost,
        round(total_cost / elapsed_days * 7, 2) as week_cost,
        round(total_cost / elapsed_days, 2) as day_cost
    FROM runrate
)
SELECT
    multiIf(input_tok >= 1000000000, concat(toString(round(input_tok / 1000000000, 2)), 'B'), input_tok >= 1000000, concat(toString(round(input_tok / 1000000, 2)), 'M'), input_tok >= 1000, concat(toString(round(input_tok / 1000, 2)), 'K'), toString(input_tok)) as "Input Tokens",
    multiIf(cached_tok >= 1000000000, concat(toString(round(cached_tok / 1000000000, 2)), 'B'), cached_tok >= 1000000, concat(toString(round(cached_tok / 1000000, 2)), 'M'), cached_tok >= 1000, concat(toString(round(cached_tok / 1000, 2)), 'K'), toString(cached_tok)) as "Cached Tokens",
    multiIf(output_tok >= 1000000000, concat(toString(round(output_tok / 1000000000, 2)), 'B'), output_tok >= 1000000, concat(toString(round(output_tok / 1000000, 2)), 'M'), output_tok >= 1000, concat(toString(round(output_tok / 1000, 2)), 'K'), toString(output_tok)) as "Output Tokens",
    multiIf(reasoning_tok >= 1000000000, concat(toString(round(reasoning_tok / 1000000000, 2)), 'B'), reasoning_tok >= 1000000, concat(toString(round(reasoning_tok / 1000000, 2)), 'M'), reasoning_tok >= 1000, concat(toString(round(reasoning_tok / 1000, 2)), 'K'), toString(reasoning_tok)) as "Reasoning Tokens",
    concat(multiIf(total_tok >= 1000000000, concat(toString(round(total_tok / 1000000000, 2)), 'B'), total_tok >= 1000000, concat(toString(round(total_tok / 1000000, 2)), 'M'), total_tok >= 1000, concat(toString(round(total_tok / 1000, 2)), 'K'), toString(total_tok)), ' / $', toString(floor(round(total_cost * 100) / 100)), '.', leftPad(toString(round(total_cost * 100) % 100), 2, '0')) as "Total",
    concat(multiIf(month_tok >= 1000000000, concat(toString(round(month_tok / 1000000000, 2)), 'B'), month_tok >= 1000000, concat(toString(round(month_tok / 1000000, 2)), 'M'), month_tok >= 1000, concat(toString(round(month_tok / 1000, 2)), 'K'), toString(month_tok)), ' / $', toString(floor(round(month_cost * 100) / 100)), '.', leftPad(toString(round(month_cost * 100) % 100), 2, '0')) as "Monthly Average",
    concat(multiIf(week_tok >= 1000000000, concat(toString(round(week_tok / 1000000000, 2)), 'B'), week_tok >= 1000000, concat(toString(round(week_tok / 1000000, 2)), 'M'), week_tok >= 1000, concat(toString(round(week_tok / 1000, 2)), 'K'), toString(week_tok)), ' / $', toString(floor(round(week_cost * 100) / 100)), '.', leftPad(toString(round(week_cost * 100) % 100), 2, '0')) as "Weekly Average",
    concat(multiIf(day_tok >= 1000000000, concat(toString(round(day_tok / 1000000000, 2)), 'B'), day_tok >= 1000000, concat(toString(round(day_tok / 1000000, 2)), 'M'), day_tok >= 1000, concat(toString(round(day_tok / 1000, 2)), 'K'), toString(day_tok)), ' / $', toString(floor(round(day_cost * 100) / 100)), '.', leftPad(toString(round(day_cost * 100) % 100), 2, '0')) as "Daily Average"
FROM avgs
