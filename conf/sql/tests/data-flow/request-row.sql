-- request_log metadata row for one request id.
SELECT request_id, model, status, client_ip, request_size, upstream_response_time_s
FROM llm_gateway.request_log
WHERE request_id = '{{ RID }}' LIMIT 1
