#!/usr/bin/env bash
# migrate-opencode-stats.sh - Backfill opencode SQLite stats into ClickHouse.
# Docs: docs/specifications/SPEC-STATS-MIGRATION.md (field maps, dedup keys).
set -euo pipefail

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
    _SELF="$SHG_SCRIPT_PATH"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DRY_RUN=false
BACKUP_DIR=""
CH_URL="${CLICKHOUSE_URL:-http://localhost:8123}"
DB="${DATABASE:-llm_gateway}"
BATCH_SIZE="${BATCH_SIZE:-5000}"
OPENCODE_DBS="${OPENCODE_DBS:-$HOME/.local/share/opencode/opencode.db:$HOME/.local/share/opencode/opencode-dev.db}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --clickhouse-url) CH_URL="$2"; shift 2 ;;
        --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
        *) echo "Usage: $(basename "$0") [--dry-run] [--clickhouse-url <url>] [--backup-dir <dir>]" >&2; exit 2 ;;
    esac
done

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

ch() {
    local code
    if ! code=$(printf '%s' "$1" | curl -sS --max-time 300 -o "$TMPD/resp.txt" -w '%{http_code}' \
            "$CH_URL/" --data-binary @-); then
        echo "[FAIL] ClickHouse request error" >&2; return 1
    fi
    if [ "$code" != "200" ]; then
        echo "[FAIL] ClickHouse query failed (HTTP $code): $1" >&2
        cat "$TMPD/resp.txt" >&2
        return 1
    fi
    cat "$TMPD/resp.txt"
}

# ---------------------------------------------------------------- registry
awk '
  /^  [^ ]/  { cur=$1; sub(/:$/,"",cur) }
  /^      - /{ print cur "\t" $2 }
' "$REPO_ROOT/conf/model-registry.yaml" > "$TMPD/aliases.tsv"

# ---------------------------------------------------------------- extract
# parts stream: message_id \t session_id \t part_tc_ms \t hex("type:text")
#               \t text_bytes   (all roles, ordered by message_id, part.id)
# messages (15 ts string, UTC):
#   id, session_id, tc_ms, providerID, modelID, cost, input, output,
#   reasoning, cache_read, agent, project_id, parent_id, version, ts
: > "$TMPD/msg.tsv"
: > "$TMPD/hash.tsv"
: > "$TMPD/partstream.tsv"

IFS=':' read -ra DBS_ARR <<< "$OPENCODE_DBS"
for SRC in "${DBS_ARR[@]}"; do
    [ -n "$SRC" ] || continue
    if [ ! -f "$SRC" ]; then
        echo "[WARN] source not found, skipping: $SRC" >&2
        continue
    fi
    URI="file:${SRC}?mode=ro"
    echo "[INFO] extracting $SRC" >&2

    sqlite3 -cmd ".timeout 10000" -batch -separator $'\t' "$URI" "
SELECT p.message_id, p.session_id, p.time_created,
       hex(json_extract(p.data,'\$.type') || ':' || coalesce(json_extract(p.data,'\$.text'),'')),
       length(CAST(coalesce(json_extract(p.data,'\$.text'),'') AS BLOB))
FROM part p
WHERE json_extract(p.data,'\$.type') IN ('text','reasoning')
ORDER BY p.message_id, p.id;
" | awk -F'\t' -v hashf="$TMPD/hash.tsv" -v streamf="$TMPD/partstream.tsv" '
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

    sqlite3 -cmd ".timeout 10000" -batch -separator $'\t' "$URI" "
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
        strftime('%Y-%m-%d %H:%M:%f', m.time_created/1000.0, 'unixepoch')
FROM message m JOIN session s ON s.id = m.session_id
WHERE json_extract(m.data,'\$.role')='assistant'
ORDER BY m.id;
" >> "$TMPD/msg.tsv"
done

EXTRACTED=$(wc -l < "$TMPD/msg.tsv")
echo "[INFO] extracted $EXTRACTED assistant message(s)" >&2
if [ "$EXTRACTED" -eq 0 ]; then
    echo "[OK] nothing to do"
    exit 0
fi

# ------------------------------------------------------------ join + map
# out fields:
#  1 msg_id 2 session_id 3 tc_ms 4 provider 5 model_raw 6 model_canon
#  7 cost 8 pt 9 ct 10 rt 11 cached 12 agent 13 project_id 14 parent_id
#  15 version 16 ts 17 content_hash 18 resp_bytes
awk -F'\t' -v OFS='\t' '
    NR==FNR { alias[$2]=$1; next }
    FILENAME==ARGV[2] { hash[$1]=$2; bytes[$1]=$3; next }
    {
        m = tolower($5)
        if (m in alias) c = alias[m]
        else { seg=m; sub(/.*\//,"",seg); c = (seg in alias) ? alias[seg] : seg }
        print $1,$2,$3,$4,$5,c,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,hash[$1],bytes[$1]+0
    }
' "$TMPD/aliases.tsv" "$TMPD/hash.tsv" "$TMPD/msg.tsv" > "$TMPD/joined.tsv"

# ------------------------------------------------- natural-key dedup
# key: session_id, provider, model_raw, tc, content_hash ; keep min msg_id
sort -t $'\t' -k2,2 -k4,4 -k5,5 -k3,3n -k17,17 -k1,1 "$TMPD/joined.tsv" \
 | awk -F'\t' '{
     k=$2 FS $4 FS $5 FS $3 FS $17
     if (!(k in seen)) { seen[k]=1; print }
   }' > "$TMPD/dedup.tsv"

# ------------------------------------- pseudo request_size (context bytes)
# request_size = session content bytes (text/reasoning parts, all roles -
# user parts are the prompt) with part.time_created < message.time_created,
# excluding only replay-duplicate assistant messages that lost the dedup.
# Two-pointer over both streams sorted by (session, time).
LC_ALL=C sort -t $'\t' -k2,2 -k3,3n "$TMPD/partstream.tsv" > "$TMPD/ps.sorted"
LC_ALL=C sort -t $'\t' -k2,2 -k3,3n "$TMPD/dedup.tsv" > "$TMPD/ds.sorted"
awk -F'\t' -v OFS='\t' '
    NR==FNR { keep[$1]=1; next }
    FILENAME==ARGV[2] { if (!($1 in keep)) drop[$1]=1; next }
    FILENAME==ARGV[3] {
        if ($1 in drop) next
        np++
        ps[np]=$2; pt[np]=$3+0; pb[np]=$4+0
        if (!($2 in start)) start[$2]=np
        next
    }
    {
        s=$2; mtc=$3+0
        i = (s in cur) ? cur[s] : (s in start ? start[s] : np+1)
        a = acc[s]+0
        while (i <= np && ps[i] == s && pt[i] < mtc) { a += pb[i]; i++ }
        cur[s]=i; acc[s]=a
        print $1, a, $18
    }
' "$TMPD/dedup.tsv" "$TMPD/joined.tsv" "$TMPD/ps.sorted" "$TMPD/ds.sorted" > "$TMPD/sizes.tsv"

KEPT=$(wc -l < "$TMPD/dedup.tsv")
DUPES=$((EXTRACTED - KEPT))
echo "[INFO] source duplicates collapsed: $DUPES; to migrate: $KEPT" >&2

TTL_EXPIRED=$(awk -F'\t' -v cutoff="$(( $(date +%s) - 397*86400 ))" \
    '$3 < cutoff*1000 {n++} END{print n+0}' "$TMPD/dedup.tsv")
[ "$TTL_EXPIRED" -gt 0 ] && \
    echo "[WARN] $TTL_EXPIRED row(s) older than 13-month TTL will be expired by ClickHouse" >&2

# ------------------------------------------------- dry-run report
if [ "$DRY_RUN" = true ]; then
    echo "[DRY-RUN] rows to insert: usage_log=$KEPT request_log=$KEPT"
    echo "[DRY-RUN] source duplicates collapsed: $DUPES"
    echo "[DRY-RUN] TTL-expired rows: $TTL_EXPIRED"
    if curl -sSf --max-time 5 "$CH_URL/ping" 2>&1 | grep -q 'Ok.'; then
        EX_U=$(ch "SELECT count() FROM $DB.usage_log WHERE event_id LIKE 'ocm_%'")
        EX_R=$(ch "SELECT count() FROM $DB.request_log WHERE event_id LIKE 'ocr_%'")
        echo "[DRY-RUN] already present: usage_log=$EX_U request_log=$EX_R"
    else
        echo "[DRY-RUN] ClickHouse unreachable; existing-row counts not available"
    fi
    exit 0
fi

# ------------------------------------------------- pre-insert backup
# Full dump of the three affected tables (FORMAT Native, byte-exact and
# re-insertable) plus a row-count/checksum manifest, before any write.
if [ -n "$BACKUP_DIR" ]; then
    mkdir -p "$BACKUP_DIR"
    echo "[INFO] backing up $DB tables to $BACKUP_DIR (FORMAT Native)" >&2
    : > "$BACKUP_DIR/manifest.txt"
    for t in usage_log request_log billing_ledger; do
        cnt=$(ch "SELECT count() FROM $DB.$t")
        cks=$(ch "SELECT sum(cityHash64(*)) FROM $DB.$t")
        printf '%s\trows=%s\tcityHash64sum=%s\n' "$t" "$cnt" "$cks" \
            >> "$BACKUP_DIR/manifest.txt"
        if ! curl -sS --max-time 600 -o "$BACKUP_DIR/$t.native" \
                "$CH_URL/" --data-binary "SELECT * FROM $DB.$t FORMAT Native"; then
            echo "[FAIL] backup dump of $t failed" >&2
            exit 1
        fi
    done
    echo "[OK] backup complete: $BACKUP_DIR" >&2
fi

# ------------------------------------------------- row materialization
# usage fields: event_id request_id model model_raw pt ct tt rt cached
#               aborted is_stream cost cost_source provider_id ts
# Token mapping replicates sse_usage_lib.lua extract_tokens upstream
# semantics: prompt INCLUDES cached, completion INCLUDES reasoning
# (opencode stores input/output/cache.read/reasoning disjoint).
awk -F'\t' -v OFS='\t' '
    {
        cs = ($7+0 > 0) ? "upstream" : "unknown"
        pt = $8 + $11
        ct = $9 + $10
        print "ocm_" $1, $1, $6, $5, pt, ct, pt+ct, $10+0, $11+0, \
              0, 1, $7+0, cs, $4, $16
    }
' "$TMPD/dedup.tsv" > "$TMPD/usage.tsv"

jq -cRn '
    inputs | split("\t") as $f |
    { event_id: $f[0], request_id: $f[1], model: $f[2], model_raw: $f[3],
      prompt_tokens: ($f[4]|tonumber), completion_tokens: ($f[5]|tonumber),
      total_tokens: ($f[6]|tonumber), cached_tokens: ($f[8]|tonumber),
      reasoning_tokens: ($f[7]|tonumber), aborted: ($f[9]|tonumber),
      is_stream: ($f[10]|tonumber), cost: ($f[11]|tonumber),
      cost_source: $f[12], provider_id: $f[13], timestamp: $f[14] }
' "$TMPD/usage.tsv" > "$TMPD/usage.jsonl"

# request fields: event_id provider model model_raw session_id project_id
#                 parent_session_id agent_name opencode_version user_agent
#                 request_id ts request_size response_size
awk -F'\t' -v OFS='\t' '
    NR==FNR { rq[$1]=$2; rp[$1]=$3; next }
    {
        print "ocr_" $1, $4, $6, $5, $2, $13, $14, $12, $15, \
              "opencode/" $15, $1, $16, rq[$1]+0, rp[$1]+0
    }
' "$TMPD/sizes.tsv" "$TMPD/dedup.tsv" > "$TMPD/request.tsv"

jq -cRn '
    inputs | split("\t") as $f |
    { event_id: $f[0], provider: $f[1], model: $f[2], model_raw: $f[3],
      method: "POST", uri: "/v1/chat/completions", status: 200,
      stream: true, session_id: $f[4], project_id: $f[5],
      parent_session_id: $f[6], agent_name: $f[7],
      opencode_version: $f[8], user_agent: $f[9],
      request_id: $f[10], timestamp: $f[11],
      request_size: ($f[12]|tonumber), response_size: ($f[13]|tonumber),
      client_type: "migrated" }
' "$TMPD/request.tsv" > "$TMPD/request.jsonl"

# ------------------------------------------------- batched insert
insert_table() {
    local table="$1" jsonl="$2"
    local total inserted=0 skipped=0
    total=$(wc -l < "$jsonl")
    split -l "$BATCH_SIZE" "$jsonl" "$TMPD/batch_"
    for b in "$TMPD"/batch_*; do
        [ -s "$b" ] || continue
        local ids exist keep
        ids=$(jq -r '.event_id' "$b" | awk 'BEGIN{q="\x27"} {printf "%s", (NR>1?",":"") q $0 q}')
        exist=$(ch "SELECT event_id FROM $DB.$table WHERE event_id IN ($ids)")
        if [ -n "$exist" ]; then
            printf '%s\n' "$exist" | sort > "$TMPD/exist.txt"
            jq -r '.event_id' "$b" | sort > "$TMPD/batch_ids.txt"
            comm -23 "$TMPD/batch_ids.txt" "$TMPD/exist.txt" > "$TMPD/keep_ids.txt"
            keep=$(wc -l < "$TMPD/keep_ids.txt")
            skipped=$((skipped + $(wc -l < "$TMPD/exist.txt")))
        else
            jq -r '.event_id' "$b" > "$TMPD/keep_ids.txt"
            keep=$(wc -l < "$TMPD/keep_ids.txt")
        fi
        if [ "$keep" -gt 0 ]; then
            if ! grep -F -f "$TMPD/keep_ids.txt" "$b" > "$TMPD/keep.jsonl"; then
                echo "[FAIL] batch filter produced no rows" >&2; return 1
            fi
            local code
            if ! code=$({ printf 'INSERT INTO %s.%s FORMAT JSONEachRow\n' "$DB" "$table"; cat "$TMPD/keep.jsonl"; } \
                | curl -sS --max-time 300 -X POST "$CH_URL/" --data-binary @- \
                    -o "$TMPD/resp.txt" -w '%{http_code}'); then
                echo "[FAIL] insert request error for $table" >&2; return 1
            fi
            if [ "$code" != "200" ]; then
                echo "[FAIL] insert into $table failed (HTTP $code):" >&2
                cat "$TMPD/resp.txt" >&2
                return 1
            fi
            inserted=$((inserted + keep))
        fi
    done
    rm -f "$TMPD"/batch_* "$TMPD/exist.txt" "$TMPD/batch_ids.txt" "$TMPD/keep_ids.txt" "$TMPD/keep.jsonl" "$TMPD/resp.txt"
    echo "[OK] $table: inserted=$inserted skipped_existing=$skipped of $total"
}

insert_table usage_log "$TMPD/usage.jsonl"
insert_table request_log "$TMPD/request.jsonl"
echo "[OK] migration complete"
