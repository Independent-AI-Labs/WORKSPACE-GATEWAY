-- Guard against curl's multi-part '&' join corrupting request_ids.
SELECT countIf(request_id LIKE '&%') FROM llm_gateway.request_signals
