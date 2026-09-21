-- 000010 down: restore body columns into request_log and copy back from
-- request_bodies (anti-join keeps existing rows untouched), then drop the
-- body table. Rows whose bodies were both empty were never copied up, they
-- are irrecoverable in down (documented, acceptable).
ALTER TABLE llm_gateway.request_log ADD COLUMN IF NOT EXISTS req_body String DEFAULT '';
ALTER TABLE llm_gateway.request_log ADD COLUMN IF NOT EXISTS resp_body String DEFAULT '';

INSERT INTO llm_gateway.request_log (event_id, request_id, req_body, resp_body)
SELECT rb.event_id, rb.request_id, rb.req_body, rb.resp_body
FROM llm_gateway.request_bodies rb
LEFT ANTI JOIN (
    SELECT event_id, request_id FROM llm_gateway.request_log
) rl ON rb.event_id = rl.event_id AND rb.request_id = rl.request_id;

DROP TABLE IF EXISTS llm_gateway.request_bodies;
