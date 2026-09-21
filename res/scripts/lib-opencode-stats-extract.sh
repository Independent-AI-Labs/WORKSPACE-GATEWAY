#!/usr/bin/env bash
# lib-opencode-stats-extract.sh - SQLite row extraction for
# migrate-opencode-stats.sh, kept in its own file to hold the entry script
# within the module-size limit. Sourced, never executed directly.
#
# The caller creates the empty target TSV files under TMPD before calling.

extract_opencode_rows() {
    local dbs="${1:?OPENCODE_DBS required}"
    local tmpd="${2:?TMPD required}"
    local src uri
    local -a dbs_arr
    IFS=':' read -ra dbs_arr <<< "$dbs"
    for src in "${dbs_arr[@]}"; do
        [ -n "$src" ] || continue
        if [ ! -f "$src" ]; then
            echo "[WARN] source not found, skipping: $src" >&2
            continue
        fi
        uri="file:${src}?mode=ro"
        echo "[INFO] extracting $src" >&2

        sqlite3 -cmd ".timeout 10000" -batch -separator $'\t' "$uri" "
SELECT p.message_id, p.session_id, p.time_created,
       hex(json_extract(p.data,'\$.type') || ':' || coalesce(json_extract(p.data,'\$.text'),'')),
       length(CAST(coalesce(json_extract(p.data,'\$.text'),'') AS BLOB))
FROM part p
WHERE json_extract(p.data,'\$.type') IN ('text','reasoning')
ORDER BY p.message_id, p.id;
" | awk -F'\t' -v hashf="$tmpd/hash.tsv" -v streamf="$tmpd/partstream.tsv" '
    function flush() {
        if (cur == "") return
        cmd = "printf %s \x27" buf "\x27 | md5sum"
        cmd | getline line
        close(cmd)
        split(line, a, " ")
        print cur "\t" a[1] "\t" bytes >> hashf
    }
    {
        print $1 "\t" $2 "\t" $3 "\t" $5 >> streamf
        if ($1 != cur) { flush(); cur = $1; buf = $4; bytes = $5+0 }
        else { buf = buf "0A" $4; bytes += $5 }
    }
    END { flush() }
'

        sqlite3 -cmd ".timeout 10000" -batch -separator $'\t' "$uri" "
SELECT m.id, m.session_id, m.time_created,
       coalesce(json_extract(m.data,'\$.providerID'),''),
       coalesce(json_extract(m.data,'\$.modelID'),''),
       coalesce(json_extract(m.data,'\$.cost'),0),
       coalesce(json_extract(m.data,'\$.tokens.input'),0),
       coalesce(json_extract(m.data,'\$.tokens.output'),0),
       coalesce(json_extract(m.data,'\$.tokens.reasoning'),0),
       coalesce(json_extract(m.data,'\$.tokens.cache.read'),0),
       coalesce(json_extract(m.data,'\$.agent'), coalesce(s.agent,''), ''),
       coalesce(s.project_id,''), coalesce(s.parent_id,''), s.version,
        strftime('%Y-%m-%d %H:%M:%f', m.time_created/1000.0, 'unixepoch'),
       coalesce(json_extract(m.data,'\$.error.name'),''),
       coalesce(json_extract(m.data,'\$.time.completed'),0)
FROM message m JOIN session s ON s.id = m.session_id
WHERE json_extract(m.data,'\$.role')='assistant'
ORDER BY m.id;
" >> "$tmpd/msg.tsv"

        # First visible (non-reasoning) part per message: content TTFT input.
        sqlite3 -cmd ".timeout 10000" -batch -separator $'\t' "$uri" "
SELECT message_id, min(time_created) FROM part
WHERE json_extract(data,'\$.type') != 'reasoning'
GROUP BY message_id ORDER BY message_id;
" >> "$tmpd/firstpart.tsv"

        # Role timeline per session (req_body synthesis: prior assistant turns
        # detect followup requests the way resent conversation history would).
        sqlite3 -cmd ".timeout 10000" -batch -separator $'\t' "$uri" "
SELECT m.id, m.session_id, m.time_created, coalesce(json_extract(m.data,'\$.role'),'')
FROM message m ORDER BY m.session_id, m.time_created;
" >> "$tmpd/roles.tsv"

        # User prompt texts plus tool/marker texts carrying guard-block and
        # permission-rejection markers (same marker strings the usefulness
        # cruncher counts). Text sanitized to single-line, capped at 64 KiB.
        sqlite3 -cmd ".timeout 10000" -batch -separator $'\t' "$uri" "
SELECT p.message_id, p.session_id, p.time_created,
       CASE WHEN json_extract(m.data,'\$.role')='user' THEN 'U' ELSE 'M' END,
       replace(replace(replace(substr(coalesce(json_extract(p.data,'\$.text'),''),1,65536),
         char(9),' '), char(10),' '), char(13),' ')
FROM part p JOIN message m ON m.id = p.message_id
WHERE (json_extract(m.data,'\$.role')='user' AND json_extract(p.data,'\$.type')='text')
   OR json_extract(p.data,'\$.text') LIKE '%BLOCKED: bash %'
   OR json_extract(p.data,'\$.text') LIKE '%BLOCKED: ts=%'
   OR json_extract(p.data,'\$.text') LIKE '%The user rejected permission to use this specific tool call%'
   OR json_extract(p.data,'\$.text') LIKE '%The user has specified a rule which prevents you from using this specific tool call%'
ORDER BY p.session_id, p.time_created;
" >> "$tmpd/usermark.tsv"
    done
}
