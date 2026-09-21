#!/usr/bin/env bash
# lib-opencode-stats-extract.sh - SQLite row extraction for
# migrate-opencode-stats.sh, kept in its own file to hold the entry script
# within the module-size limit. Sourced, never executed directly.
#
# The caller creates the empty target TSV files under TMPD before calling.

_LIB_SQL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$_LIB_SQL_DIR/../.." && pwd)}"
# shellcheck source=lib-sql.sh
source "$_LIB_SQL_DIR/lib-sql.sh" || return 1

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
        sqlite3 -cmd ".timeout 10000" -batch -separator $'\t' "$uri" \
            "$(sql_render sqlite/opencode-stats/messages.sql)" >> "$tmpd/msg.tsv"
        t1=$(date +%s%3N)
        echo "[TIME] messages $((t1 - t0))ms" >&2

        # First visible (non-reasoning) part per message: content TTFT input.
        t0=$(date +%s%3N)
        sqlite3 -cmd ".timeout 10000" -batch -separator $'\t' "$uri" \
            "$(sql_render sqlite/opencode-stats/firstpart.sql)" >> "$tmpd/firstpart.tsv"
        t1=$(date +%s%3N)
        echo "[TIME] firstpart $((t1 - t0))ms" >&2

        # Role timeline per session (req_body synthesis: prior assistant turns
        # detect followup requests the way resent conversation history would).
        t0=$(date +%s%3N)
        sqlite3 -cmd ".timeout 10000" -batch -separator $'\t' "$uri" \
            "$(sql_render sqlite/opencode-stats/roles.sql)" >> "$tmpd/roles.tsv"
        t1=$(date +%s%3N)
        echo "[TIME] roles $((t1 - t0))ms" >&2

        # User prompt texts plus tool/marker texts carrying guard-block and
        # permission-rejection markers (same marker strings the usefulness
        # cruncher counts). Text sanitized to single-line, capped at 64 KiB.
        t0=$(date +%s%3N)
        sqlite3 -cmd ".timeout 10000" -batch -separator $'\t' "$uri" \
            "$(sql_render sqlite/opencode-stats/usermark.sql)" >> "$tmpd/usermark.tsv"
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
        sqlite3 -cmd ".timeout 10000" -batch -separator $'\t' "$uri" \
            "$(sql_render sqlite/opencode-stats/parts.sql)" | awk -F'\t' -v needf="$tmpd/needs_hash.txt" -v hashf="$tmpd/hash.tsv" -v streamf="$tmpd/partstream.tsv" '
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
