SELECT p.id, m.session_id, json_extract(p.data,'$.type')
FROM part p JOIN message m ON m.id = p.message_id
WHERE (json_extract(p.data,'$.type')='reasoning' AND json_extract(p.data,'$.text')='')
   OR (json_extract(p.data,'$.type')='text' AND json_extract(p.data,'$.text')=''
       AND json_extract(m.data,'$.role')='assistant');
