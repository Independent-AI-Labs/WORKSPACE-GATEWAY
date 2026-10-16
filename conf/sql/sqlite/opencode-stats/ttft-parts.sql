/* backfill-migrated-ttft.sh: per-message content TTFT from the first output
   part of ANY type (text/reasoning/tool). Mirrors the migrator's timing rule
   (deltas outside [0, 1h) mean missing/corrupt timestamps -> 0), so a
   reasoning-first message is stamped at its first reasoning token rather than
   the later visible answer text. */
SELECT m.id,
       CASE
           WHEN min(p.time_created) - coalesce(json_extract(m.data, '$.time.created'), m.time_created) < 0 THEN 0
           WHEN min(p.time_created) - coalesce(json_extract(m.data, '$.time.created'), m.time_created) >= 3600000 THEN 0
           ELSE min(p.time_created) - coalesce(json_extract(m.data, '$.time.created'), m.time_created)
       END
FROM message AS m
JOIN part AS p ON p.message_id = m.id
WHERE json_extract(m.data, '$.role') = 'assistant'
  AND json_extract(p.data, '$.type') IN ('text', 'reasoning', 'tool')
GROUP BY m.id
ORDER BY m.id;