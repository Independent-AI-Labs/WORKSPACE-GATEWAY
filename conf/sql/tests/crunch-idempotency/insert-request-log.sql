-- Seed request_log metadata rows (JSONEachRow) for the crunch test window.
INSERT INTO llm_gateway.request_log
(event_id, request_id, provider, model, stream, method, uri, status, timestamp)
FORMAT JSONEachRow
{"event_id":"00000000-0000-0000-0000-0000000000a1","request_id":"crunch-test-a","provider":"test","model":"test-model","stream":true,"method":"POST","uri":"/v1/chat/completions","status":200,"timestamp":"{{ WT0 }}"}
{"event_id":"00000000-0000-0000-0000-0000000000b1","request_id":"crunch-test-b","provider":"test","model":"test-model","stream":true,"method":"POST","uri":"/v1/chat/completions","status":200,"timestamp":"{{ WT0 }}"}
{"event_id":"00000000-0000-0000-0000-0000000000c1","request_id":"crunch-test-c","provider":"test","model":"test-model","stream":true,"method":"POST","uri":"/v1/chat/completions","status":200,"timestamp":"{{ WT0 }}"}
{"event_id":"00000000-0000-0000-0000-0000000000d1","request_id":"crunch-test-d","provider":"test","model":"test-model","stream":true,"method":"POST","uri":"/v1/chat/completions","status":200,"timestamp":"{{ WT0 }}"}
{"event_id":"00000000-0000-0000-0000-0000000000e1","request_id":"crunch-test-e","provider":"test","model":"test-model","stream":true,"method":"POST","uri":"/v1/chat/completions","status":200,"timestamp":"{{ WT0 }}"}
