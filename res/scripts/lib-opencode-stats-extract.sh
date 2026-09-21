#!/usr/bin/env bash
# lib-opencode-stats-extract.sh - SQLite row extraction for
# migrate-opencode-stats.sh, kept in its own file to hold the entry script
# within the module-size limit. Sourced, never executed directly.
#
# The caller creates the empty target TSV files under TMPD before calling.

extract_opencode_rows() {
    local dbs="${1:?OPENCODE_DBS required}"
    local tmpd="${2:?TMPD required}"
    local src uri t0 t1
    local -a dbs_arr
    IFS=':' read -ra dbs_arr <<< "$dbs"

    # Pass 1: message metadata, role timeline and marker inputs. The content
    # hash backing dedup is only needed for messages that share a natural key
    # (session, provider, model_raw, time_created); those keys are collected
    # across ALL sources below, then only the collisions are hashed in pass 2.
    # On real data the collision set is empty, which removes ~60k per-message
    # md5sum forks (the single dominant migration cost: ~4.5 min).
    for src in "${dbs_arr[@]}"; do
        [ -n "$src" ] || continue
        if [ ! -f "$src" ]; then
            echo "[WARN] source not found, skipping: $src" >&2
            continue
        fi
        uri="file:${src}?mode=ro"
        echo "[INFO] extracting $src" >&2

        t0=$(date +%s%3N)
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
       coalesce(json_extract(m.data,'\$.time.completed'),0),
       coalesce(json_extract(m.data,'\$.tokens.cache.write'),0)
FROM message m JOIN session s ON s.id = m.session_id
WHERE json_extract(m.data,'\$.role')='assistant'
ORDER BY m.id;
" >> "$tmpd/msg.tsv"
        t1=$(date +%s%3N)
        echo "[TIME] messages $((t1 - t0))ms" >&2

        # First visible (non-reasoning) part per message: content TTFT input.
        t0=$(date +%s%3N)
        sqlite3 -cmd ".timeout 10000" -batch -separator $'\t' "$uri" "
SELECT message_id, min(time_created) FROM part
WHERE json_extract(data,'\$.type') != 'reasoning'
GROUP BY message_id ORDER BY message_id;
" >> "$tmpd/firstpart.tsv"
        t1=$(date +%s%3N)
        echo "[TIME] firstpart $((t1 - t0))ms" >&2

        # Role timeline per session (req_body synthesis: prior assistant turns
        # detect followup requests the way resent conversation history would).
        t0=$(date +%s%3N)
        sqlite3 -cmd ".timeout 10000" -batch -separator $'\t' "$uri" "
SELECT m.id, m.session_id, m.time_created, coalesce(json_extract(m.data,'\$.role'),'')
FROM message m ORDER BY m.session_id, m.time_created;
" >> "$tmpd/roles.tsv"
        t1=$(date +%s%3N)
        echo "[TIME] roles $((t1 - t0))ms" >&2

        # User prompt texts plus tool/marker texts carrying guard-block and
        # permission-rejection markers (same marker strings the usefulness
        # cruncher counts). Text sanitized to single-line, capped at 64 KiB.
        t0=$(date +%s%3N)
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
        t1=$(date +%s%3N)
        echo "[TIME] usermark $((t1 - t0))ms" >&2
    done

    # Natural-key collisions: which messages actually need a content hash.
    awk -F'\t' -v OFS='\t' '
        { k = $2 FS $4 FS $5 FS $3; c[k]++; ids[k] = ids[k] "\n" $1 }
        END {
            for (k in c) {
                if (c[k] < 2) continue
                n = split(ids[k], a, "\n")
                for (i = 1; i <= n; i++) if (a[i] != "") print a[i]
            }
        }
    ' "$tmpd/msg.tsv" > "$tmpd/needs_hash.txt"
    echo "[INFO] messages needing content hash: $(wc -l < "$tmpd/needs_hash.txt")" >&2

    # Pass 2: parts stream + content hash for collision messages only.
    for src in "${dbs_arr[@]}"; do
        [ -n "$src" ] || continue
        if [ ! -f "$src" ]; then
            continue
        fi
        uri="file:${src}?mode=ro"

        t0=$(date +%s%3N)
        sqlite3 -cmd ".timeout 10000" -batch -separator $'\t' "$uri" "
SELECT p.message_id, p.session_id, p.time_created,
       hex(json_extract(p.data,'\$.type') || ':' || coalesce(json_extract(p.data,'\$.text'),'')),
       length(CAST(coalesce(json_extract(p.data,'\$.text'),'') AS BLOB))
FROM part p
WHERE json_extract(p.data,'\$.type') IN ('text','reasoning')
ORDER BY p.message_id, p.id;
" | awk -F'\t' -v needf="$tmpd/needs_hash.txt" -v hashf="$tmpd/hash.tsv" -v streamf="$tmpd/partstream.tsv" '
    BEGIN { while ((getline l < needf) > 0) need[l] = 1 }
    function flush() {
        if (cur == "") return
        h = ""
        if (cur in need) {
            cmd = "printf %s \x27" buf "\x27 | md5sum"
            cmd | getline line
            close(cmd)
            split(line, a, " ")
            h = a[1]
        }
        print cur "\t" h "\t" bytes >> hashf
    }
    {
        print $1 "\t" $2 "\t" $3 "\t" $5 >> streamf
        if ($1 != cur) { flush(); cur = $1; buf = $4; bytes = $5+0 }
        else { buf = buf "0A" $4; bytes += $5 }
    }
    END { flush() }
'
        t1=$(date +%s%3N)
        echo "[TIME] parts+hash $((t1 - t0))ms" >&2
    done
}
