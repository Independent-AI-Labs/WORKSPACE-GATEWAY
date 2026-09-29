-- p3 CTE + raw token and per-category cost columns (cross-check).
{{ CTE }}
SELECT total_tok, input_tok, cached_tok, output_tok, reasoning_tok,
       input_cost, cached_cost, output_cost, reasoning_cost, total_cost
FROM totals FORMAT TabSeparated
