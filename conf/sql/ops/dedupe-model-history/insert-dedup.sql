INSERT INTO {{ DB }}.request_log_dedup
SELECT * REPLACE ({{ MODEL_MULTIIF }} AS model)
FROM {{ DB }}.request_log
