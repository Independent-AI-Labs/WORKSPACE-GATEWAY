-- Model-attribution drift guard (read-only). Counts rows where an
-- authoritative sibling already holds the model but this table does not, plus
-- any raw failing the model-id shape guard. All zero means the reconciler has
-- no work, and the score cannot quietly drop requests on an empty
-- request_signals.model join key.
SELECT
    (SELECT count()
     FROM {{ DB }}.request_log AS r
     INNER JOIN (
         SELECT request_id, any(model) AS m
         FROM {{ DB }}.usage_log
         WHERE request_id != '' AND model != ''
         GROUP BY request_id
     ) AS u ON r.request_id = u.request_id
     WHERE r.model = '' OR r.model != u.m) AS req_mismatch,
    (SELECT count()
     FROM {{ DB }}.usage_log AS u
     INNER JOIN (
         SELECT request_id, any(model) AS m
         FROM {{ DB }}.request_log
         WHERE request_id != '' AND model != ''
         GROUP BY request_id
     ) AS r ON u.request_id = r.request_id
     WHERE u.model = '' OR u.model != r.m) AS usage_mismatch,
    (SELECT count()
     FROM {{ DB }}.billing_ledger AS b
     INNER JOIN (
         SELECT event_id, any(model) AS m
         FROM {{ DB }}.usage_log
         WHERE event_id != '' AND model != ''
         GROUP BY event_id
     ) AS u ON b.event_id = u.event_id
     WHERE b.model_name = '' OR b.model_name != u.m) AS billing_mismatch,
    (SELECT count()
     FROM {{ DB }}.request_signals AS s
     INNER JOIN (
         SELECT request_id, any(model) AS m
         FROM {{ DB }}.usage_log
         WHERE request_id != '' AND model != ''
         GROUP BY request_id
     ) AS u ON s.request_id = u.request_id
     WHERE s.model != u.m) AS signals_mismatch,
    (SELECT countIf(model_raw != '' AND match(model_raw, '^[A-Za-z0-9._/-]+$') = 0) FROM {{ DB }}.request_log)
    + (SELECT countIf(model_raw != '' AND match(model_raw, '^[A-Za-z0-9._/-]+$') = 0) FROM {{ DB }}.usage_log)
    + (SELECT countIf(model_raw != '' AND match(model_raw, '^[A-Za-z0-9._/-]+$') = 0) FROM {{ DB }}.billing_ledger) AS garbage_raw
FORMAT TabSeparatedWithNames
