SELECT count(*) FROM part
WHERE (json_extract(data,'$.type')='reasoning' AND json_extract(data,'$.text')='')
   OR (json_extract(data,'$.type')='text' AND json_extract(data,'$.text')=''
       AND json_extract((SELECT m.data FROM message m WHERE m.id=part.message_id),'$.role')='assistant');
