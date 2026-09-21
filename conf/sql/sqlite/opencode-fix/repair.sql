UPDATE part
SET data = json_set(data, '$.text', '[reasoning interrupted]'),
    time_updated = {{ NOW_MS }}
WHERE json_extract(data,'$.type')='reasoning' AND json_extract(data,'$.text')='';

UPDATE part
SET data = json_set(data, '$.text', ' '),
    time_updated = {{ NOW_MS }}
WHERE json_extract(data,'$.type')='text' AND json_extract(data,'$.text')=''
  AND json_extract((SELECT m.data FROM message m WHERE m.id=part.message_id),'$.role')='assistant';
