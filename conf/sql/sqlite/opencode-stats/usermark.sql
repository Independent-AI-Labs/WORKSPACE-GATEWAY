SELECT p.message_id, p.session_id, p.time_created,
       CASE WHEN json_extract(m.data,'$.role')='user' THEN 'U' ELSE 'M' END,
       replace(replace(replace(substr(coalesce(json_extract(p.data,'$.text'),''),1,65536),
         char(9),' '), char(10),' '), char(13),' ')
FROM part p JOIN message m ON m.id = p.message_id
WHERE (json_extract(m.data,'$.role')='user' AND json_extract(p.data,'$.type')='text')
   OR json_extract(p.data,'$.text') LIKE '%BLOCKED: bash %'
   OR json_extract(p.data,'$.text') LIKE '%BLOCKED: ts=%'
   OR json_extract(p.data,'$.text') LIKE '%The user rejected permission to use this specific tool call%'
   OR json_extract(p.data,'$.text') LIKE '%The user has specified a rule which prevents you from using this specific tool call%'
ORDER BY p.session_id, p.time_created;
