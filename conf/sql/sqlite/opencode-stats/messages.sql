SELECT m.id, m.session_id, m.time_created,
       coalesce(json_extract(m.data,'$.providerID'),''),
       coalesce(json_extract(m.data,'$.modelID'),''),
       coalesce(json_extract(m.data,'$.cost'),0),
       coalesce(json_extract(m.data,'$.tokens.input'),0),
       coalesce(json_extract(m.data,'$.tokens.output'),0),
       coalesce(json_extract(m.data,'$.tokens.reasoning'),0),
       coalesce(json_extract(m.data,'$.tokens.cache.read'),0),
       coalesce(json_extract(m.data,'$.agent'), coalesce(s.agent,''), ''),
       coalesce(s.project_id,''), coalesce(s.parent_id,''), s.version,
        strftime('%Y-%m-%d %H:%M:%f', m.time_created/1000.0, 'unixepoch'),
       coalesce(json_extract(m.data,'$.error.name'),''),
       coalesce(json_extract(m.data,'$.time.completed'),0),
       coalesce(json_extract(m.data,'$.tokens.cache.write'),0)
FROM message m JOIN session s ON s.id = m.session_id
WHERE json_extract(m.data,'$.role')='assistant'
ORDER BY m.id;
