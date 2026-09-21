-- crunch-usefulness.sh: raw rows for one aligned hourly window.
-- noqa: disable=RF02
-- SQLFluff reads ClickHouse lambda parameters (m, p) as unqualified columns.
SELECT request_id, model, toString(ts) AS ts, if(length(asst) > 0, 1, 0) AS is_followup,
       guard_blocks, guard_rules_csv, user_rejections, rule_denials, last_msg FROM (
    SELECT r.request_id AS request_id, r.model AS model, r.timestamp AS ts,
           countMatches(b.req_body, 'BLOCKED: bash ') + countMatches(b.req_body, 'BLOCKED: ts=') AS guard_blocks,
           arrayStringConcat(extractAll(b.req_body, '[(]([a-z][a-z0-9-]+)[)] [(]2[0-9]{3}-[0-9]{2}-[0-9]{2}T'), ',') AS guard_rules_csv,
           countMatches(b.req_body, 'The user rejected permission to use this specific tool call') AS user_rejections,
           countMatches(b.req_body, 'The user has specified a rule which prevents you from using this specific tool call') AS rule_denials,
           arrayFilter(m -> JSONExtractString(m, 'role') = 'assistant',
               JSONExtractArrayRaw(b.req_body, 'messages')) AS asst,
           arrayFilter(m -> JSONExtractString(m, 'role') = 'user',
               JSONExtractArrayRaw(b.req_body, 'messages')) AS usr,
           if(length(usr) > 0, usr[length(usr)], '') AS last_raw,
           if(last_raw = '', '',
             multiIf(
               JSONType(last_raw, 'content') = 'String',
                 JSONExtractString(last_raw, 'content'),
               JSONType(last_raw, 'content') = 'Array',
                 arrayStringConcat(arrayMap(
                   p -> if(JSONType(p, 'text') = 'String', JSONExtractString(p, 'text'), ''),
                   arrayFilter(p -> JSONHas(p, 'text'),
                     JSONExtractArrayRaw(last_raw, 'content'))), ' '),
               '')) AS last_msg
    FROM {{ DB }}.request_log AS r
    INNER JOIN {{ DB }}.request_bodies AS b ON r.event_id = b.event_id
    WHERE r.timestamp >= '{{ WT0 }}' AND r.timestamp < '{{ WT1 }}'
      AND b.req_body != ''
      AND isValidJSON(b.req_body)
      AND JSONType(b.req_body, 'messages') = 'Array'
      AND (r.uri LIKE '%/chat/completions%' OR r.uri LIKE '%/responses%')
)
UNION ALL
SELECT r.request_id AS request_id, r.model AS model, toString(r.timestamp) AS ts, 0 AS is_followup,
       toUInt16(0) AS guard_blocks, '' AS guard_rules_csv, toUInt16(0) AS user_rejections, toUInt16(0) AS rule_denials, '' AS last_msg
FROM {{ DB }}.request_log AS r
LEFT JOIN {{ DB }}.request_bodies AS b ON r.event_id = b.event_id
WHERE r.timestamp >= '{{ WT0 }}' AND r.timestamp < '{{ WT1 }}'
  AND (r.uri LIKE '%/chat/completions%' OR r.uri LIKE '%/responses%')
  AND (b.event_id = '' OR b.req_body = '' OR NOT isValidJSON(b.req_body)
       OR JSONType(b.req_body, 'messages') != 'Array')
{{ LIMIT_CLAUSE }}
FORMAT TabSeparated
