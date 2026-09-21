-- Cleanup probe: an ops_admin delete must be permitted.
ALTER TABLE llm_gateway.request_bodies DELETE WHERE event_id = 'sec-matrix-probe'
