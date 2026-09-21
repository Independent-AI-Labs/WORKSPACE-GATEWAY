SELECT sum(bytes_on_disk) AS total FROM system.parts WHERE database = 'llm_gateway' AND active
