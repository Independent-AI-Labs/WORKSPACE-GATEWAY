SELECT m.id, m.session_id, m.time_created, coalesce(json_extract(m.data,'$.role'),'')
FROM message m ORDER BY m.session_id, m.time_created;
