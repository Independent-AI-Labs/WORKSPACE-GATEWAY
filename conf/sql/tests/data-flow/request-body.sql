-- Non-empty request body for one request id.
SELECT req_body FROM llm_gateway.request_bodies
WHERE request_id = '{{ RID }}' AND req_body != '' LIMIT 1
