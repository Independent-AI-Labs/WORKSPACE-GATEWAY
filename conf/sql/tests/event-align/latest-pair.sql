-- Newest (event_id, request_id) pair since an optional boundary.
SELECT event_id, request_id FROM llm_gateway.{{ TABLE }}
WHERE request_id != '' {{ WHERE }}
ORDER BY timestamp DESC LIMIT 1
