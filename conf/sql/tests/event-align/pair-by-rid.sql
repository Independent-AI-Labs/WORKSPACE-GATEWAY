-- (event_id, request_id) for one request id.
SELECT event_id, request_id FROM llm_gateway.{{ TABLE }} WHERE request_id = '{{ RID }}' LIMIT 1
