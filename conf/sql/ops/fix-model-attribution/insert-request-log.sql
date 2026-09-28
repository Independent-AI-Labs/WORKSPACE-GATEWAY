-- Repair request_log model identity to the registry.
--
-- model_raw is the verbatim wire string; model is its canonical id. Valid raws
-- canonicalize through {{ CANON_EXPR }} (registry alias map, source:
-- conf/model-registry.yaml). Probe/garbage raws (CONSTPROBE, ACCESS_NO_MODEL,
-- 'x', anything with ':') are not valid and are repaired from usage_log (the
-- authoritative served-model store, joined by request_id).
--
-- Values that already agree are carried verbatim, so the swap is idempotent.
-- request_log.model is part of the ORDER BY, hence the shadow-table swap.
INSERT INTO {{ DB }}.request_log_backfill
SELECT * EXCEPT (local_raw, valid_local, umodel, uraw, uis_stream, canon_local, use_sibling, new_model, new_raw, new_stream)
       REPLACE (new_model AS model, new_raw AS model_raw, new_stream AS stream)
FROM (
    SELECT
        r.*,
        u.umodel,
        u.uraw,
        u.uis_stream,
        if(r.valid_local, {{ CANON_EXPR }}, '') AS canon_local,
        (u.umodel != '' AND if(r.valid_local, {{ CANON_EXPR }}, '') != u.umodel) AS use_sibling,
        if(u.umodel != '' AND if(r.valid_local, {{ CANON_EXPR }}, '') != u.umodel,
           u.umodel,
           if(if(r.valid_local, {{ CANON_EXPR }}, '') != '',
              if(r.valid_local, {{ CANON_EXPR }}, ''),
              if(u.umodel != '', u.umodel, r.model))) AS new_model,
        if(u.umodel != '' AND if(r.valid_local, {{ CANON_EXPR }}, '') != u.umodel,
           if(u.valid_uraw, u.uraw, if(u.umodel != '', u.umodel, r.model_raw)),
           if(r.valid_local, r.model_raw,
              if(u.valid_uraw, u.uraw, if(r.model != '', r.model, '')))) AS new_raw,
        if(r.stream, true, u.uis_stream = 1) AS new_stream
    FROM (
        SELECT *,
               model_raw AS local_raw,
               match(model_raw, '^[A-Za-z0-9._/-]+$') = 1 AS valid_local
        FROM {{ DB }}.request_log
    ) AS r
    LEFT JOIN (
        SELECT request_id,
               any(model) AS umodel,
               any(model_raw) AS uraw,
               any(is_stream) AS uis_stream,
               match(any(model_raw), '^[A-Za-z0-9._/-]+$') = 1 AS valid_uraw
        FROM {{ DB }}.usage_log
        WHERE request_id != '' AND model != ''
        GROUP BY request_id
    ) AS u ON r.request_id != '' AND r.request_id = u.request_id
) AS x
