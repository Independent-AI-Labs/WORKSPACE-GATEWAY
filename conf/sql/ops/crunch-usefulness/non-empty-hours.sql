-- crunch-usefulness.sh: hourly windows that contain qualifying rows.
SELECT DISTINCT toStartOfHour(timestamp) AS h
FROM {{ DB }}.request_log
WHERE timestamp >= '{{ WT0 }}' AND timestamp < '{{ WT1 }}'
  AND (uri LIKE '%/chat/completions%' OR uri LIKE '%/responses%')
ORDER BY h
FORMAT TabSeparated
