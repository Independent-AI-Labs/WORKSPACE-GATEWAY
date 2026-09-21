-- Count request_log rows that carry the read-only probe.
SELECT count() FROM llm_gateway.request_log FORMAT TSV
