-- Reconcile billing_ledger model identity to the registry.
--
-- model_name is the canonical id, model_raw the verbatim wire string. Rows
-- with an empty model_name are repaired from usage_log (joined by event_id,
-- the ledger's only shared key). billing_ledger has a materialized view
-- writing INTO it, so its swap runs while billing_ledger_mv is dropped and it
-- is recreated directly afterwards (see the script).
INSERT INTO {{ DB }}.billing_ledger_backfill
SELECT * EXCEPT (local_raw, valid_local, umodel, uraw, canon_local, new_name, new_raw)
       REPLACE (new_name AS model_name, new_raw AS model_raw)
FROM (
    SELECT
        b.*,
        u.umodel,
        u.uraw,
        if(b.valid_local, {{ CANON_EXPR }}, '') AS canon_local,
        if(if(b.valid_local, {{ CANON_EXPR }}, '') != '',
           if(b.valid_local, {{ CANON_EXPR }}, ''),
           if(u.umodel != '', u.umodel, b.model_name)) AS new_name,
        if(b.valid_local, b.model_raw,
           if(u.uraw != '', u.uraw, if(b.model_name != '', b.model_name, b.model_raw))) AS new_raw
    FROM (
        SELECT *,
               model_raw AS local_raw,
               match(model_raw, '^[A-Za-z0-9._/-]+$') = 1 AS valid_local
        FROM {{ DB }}.billing_ledger
    ) AS b
    LEFT JOIN (
        SELECT event_id,
               any(model) AS umodel,
               any(model_raw) AS uraw
        FROM {{ DB }}.usage_log
        WHERE event_id != '' AND model != ''
        GROUP BY event_id
    ) AS u ON b.event_id != '' AND b.event_id = u.event_id
) AS x
