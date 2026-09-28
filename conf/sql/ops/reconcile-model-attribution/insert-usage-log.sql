-- Reconcile usage_log model identity to the registry.
--
-- usage_log.model/model_raw are not part of the ORDER BY, but the remaining
-- repair needs the request_log join (rows that lost the model entirely), so a
-- shadow swap is used for the same reason as request_log. Only empty/garbage
-- values are changed; already-correct rows are carried verbatim (idempotent).
INSERT INTO {{ DB }}.usage_log_backfill
SELECT * EXCEPT (local_raw, valid_local, rmodel, rraw, canon_local, new_model, new_raw)
       REPLACE (new_model AS model, new_raw AS model_raw)
FROM (
    SELECT
        u.*,
        r.rmodel,
        r.rraw,
        if(u.valid_local, {{ CANON_EXPR }}, '') AS canon_local,
        if(if(u.valid_local, {{ CANON_EXPR }}, '') != '',
           if(u.valid_local, {{ CANON_EXPR }}, ''),
           if(r.rmodel != '', r.rmodel, u.model)) AS new_model,
        if(u.valid_local, u.model_raw,
           if(r.rraw != '', r.rraw, if(u.model != '', u.model, u.model_raw))) AS new_raw
    FROM (
        SELECT *,
               model_raw AS local_raw,
               match(model_raw, '^[A-Za-z0-9._/-]+$') = 1 AS valid_local
        FROM {{ DB }}.usage_log
    ) AS u
    LEFT JOIN (
        SELECT request_id,
               any(model) AS rmodel,
               any(model_raw) AS rraw
        FROM {{ DB }}.request_log
        WHERE request_id != ''
        GROUP BY request_id
    ) AS r ON u.request_id != '' AND u.request_id = r.request_id
) AS x
