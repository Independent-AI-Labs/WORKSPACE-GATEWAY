-- Every migrated request row must carry a parseable body with a messages array.
SELECT countIf(req_body != '' AND isValidJSON(req_body) AND JSONType(req_body, 'messages') = 'Array')
FROM llm_gateway.request_log WHERE event_id LIKE '{{ PREFIX }}%'
