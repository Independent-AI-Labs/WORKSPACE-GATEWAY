-- Grafana "All" model expansion (subquery fragment).
(SELECT DISTINCT model FROM (SELECT model FROM llm_gateway.request_log WHERE model != '' UNION ALL SELECT model FROM llm_gateway.usage_log WHERE model != ''))
