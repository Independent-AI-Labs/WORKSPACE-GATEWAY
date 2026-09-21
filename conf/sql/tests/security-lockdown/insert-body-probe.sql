-- Write probe: a vector_rw insert must be rejected by the lockdown matrix.
INSERT INTO llm_gateway.request_bodies (event_id) VALUES ('sec-matrix-probe')
