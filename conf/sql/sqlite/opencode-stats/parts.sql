SELECT p.message_id, p.session_id, p.time_created,
       hex(json_extract(p.data,'$.type') || ':' || coalesce(json_extract(p.data,'$.text'),'')),
       length(CAST(coalesce(json_extract(p.data,'$.text'),'') AS BLOB))
FROM part p
WHERE json_extract(p.data,'$.type') IN ('text','reasoning')
ORDER BY p.message_id, p.id;
