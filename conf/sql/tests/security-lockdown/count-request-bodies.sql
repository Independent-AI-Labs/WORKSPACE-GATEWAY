-- Count request_bodies rows that carry the read-only probe.
SELECT count() FROM llm_gateway.request_bodies FORMAT TSV
