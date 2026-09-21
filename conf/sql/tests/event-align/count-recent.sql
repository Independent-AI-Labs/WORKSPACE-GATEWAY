-- Count rows with a populated request_id since an optional boundary.
SELECT count() FROM llm_gateway.{{ TABLE }} WHERE request_id != '' {{ WHERE }}
