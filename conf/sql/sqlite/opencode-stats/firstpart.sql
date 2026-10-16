SELECT message_id, min(time_created) FROM part
WHERE json_extract(data, '$.type') IN ('text', 'reasoning', 'tool')
GROUP BY message_id ORDER BY message_id;
