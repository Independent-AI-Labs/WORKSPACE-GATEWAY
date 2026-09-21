-- Migrated-row probe: selected columns for one event id.
SELECT {{ COLS }} FROM llm_gateway.{{ TABLE }} WHERE event_id = '{{ EID }}'{{ FORMAT }}
