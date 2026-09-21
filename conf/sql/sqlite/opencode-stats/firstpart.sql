SELECT message_id, min(time_created) FROM part
WHERE json_extract(data,'$.type') != 'reasoning'
GROUP BY message_id ORDER BY message_id;
