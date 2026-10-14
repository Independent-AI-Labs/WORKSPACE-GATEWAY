-- Seed request_bodies (JSONEachRow); req_body values are embedded raw JSON.
INSERT INTO llm_gateway.request_bodies
(event_id, request_id, req_body, timestamp)
FORMAT JSONEachRow
{"event_id":"00000000-0000-0000-0000-0000000000a1","request_id":"crunch-test-a","req_body":{{ FOLLOWUP_BODY }},"timestamp":"{{ WT0 }}"}
{"event_id":"00000000-0000-0000-0000-0000000000b1","request_id":"crunch-test-b","req_body":{{ FIRSTTURN_BODY }},"timestamp":"{{ WT0 }}"}
{"event_id":"00000000-0000-0000-0000-0000000000c1","request_id":"crunch-test-c","req_body":{{ PHRASE_BODY }},"timestamp":"{{ WT0 }}"}
{"event_id":"00000000-0000-0000-0000-0000000000d1","request_id":"crunch-test-d","req_body":"not json at all","timestamp":"{{ WT0 }}"}
{"event_id":"00000000-0000-0000-0000-0000000000e1","request_id":"crunch-test-e","req_body":{{ FRICTION_BODY }},"timestamp":"{{ WT0 }}"}
{"event_id":"00000000-0000-0000-0000-0000000000f1","request_id":"crunch-test-f","req_body":{"model":"claude-sonnet-4-5","system":"you are helpful","messages":[{"role":"user","content":"hi"},{"role":"assistant","content":[{"type":"text","text":"answer"}]},{"role":"user","content":[{"type":"text","text":"this is shit and pathetic"}]}]},"timestamp":"{{ WT0 }}"}
