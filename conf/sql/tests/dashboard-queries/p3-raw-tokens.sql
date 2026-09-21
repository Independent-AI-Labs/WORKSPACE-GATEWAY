-- p3 CTE + raw token columns (cross-check of token consistency).
{{ CTE }}
SELECT total_tok, input_tok, cached_tok, output_tok, reasoning_tok FROM totals FORMAT TabSeparated
