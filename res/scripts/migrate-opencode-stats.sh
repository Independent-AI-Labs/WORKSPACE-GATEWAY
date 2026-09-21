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
if [ ! -f "$REPO_ROOT/res/scripts/lib-opencode-stats-extract.sh" ] \
    && [ -f "$PWD/res/scripts/lib-opencode-stats-extract.sh" ]; then
    REPO_ROOT="$PWD"
fi
if ! source "$REPO_ROOT/res/scripts/lib-opencode-stats-extract.sh"; then
    echo "[FAIL] cannot source lib-opencode-stats-extract.sh from $REPO_ROOT" >&2
    exit 1
fi

DRY_RUN=false
FORCE=false
BACKUP_DIR=""
PRICING_FILE=""
CH_URL="${CLICKHOUSE_URL:-http://localhost:8123}"
DB="${DATABASE:-llm_gateway}"
BATCH_SIZE="${BATCH_SIZE:-5000}"
OPENCODE_DBS="${OPENCODE_DBS:-$HOME/.local/share/opencode/opencode.db:$HOME/.local/share/opencode/opencode-dev.db}"
MODELS_DEV_URL="${MODELS_DEV_URL:-https://models.dev/api.json}"

# Authenticated ops access (REQ-SECURITY-HARDENING FR-1.3); no unauthenticated access.
CH_OPS_USER="${CH_OPS_USER:-ops_admin}"
: "${CH_OPS_PASSWORD:?CH_OPS_PASSWORD not set (source repo .env)}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --force) FORCE=true; shift ;;
        --clickhouse-url) CH_URL="$2"; shift 2 ;;
        --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
        --pricing-file) PRICING_FILE="$2"; shift 2 ;;
        *) echo "Usage: $(basename "$0") [--dry-run] [--force] [--clickhouse-url <url>] [--backup-dir <dir>] [--pricing-file <models.dev.json>]" >&2; exit 2 ;;
    esac
done

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

ch() {
    local code
    if ! code=$(printf '%s' "$1" | curl -sS --max-time 300 -o "$TMPD/resp.txt" -w '%{http_code}' \
            --user "$CH_OPS_USER:$CH_OPS_PASSWORD" \
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

# ---------------------------------------------------------------- pricing
# models.dev per-1M-token rates (base tier only, mirrors cost_calc.lua):
#   provider \t model(lower) \t input \t output \t cache_read
# Providers on flat-fee subscription plans publish all-zero rates; for
# those we price at the PAYG-equivalent provider listed in SHADOW_MAP.
SHADOW_MAP="zai-coding-plan:zai"

if [ -z "$PRICING_FILE" ]; then
    PRICING_FILE="$TMPD/modelsdev.json"
    if ! curl -sSf --max-time 60 -o "$PRICING_FILE" "$MODELS_DEV_URL"; then
        echo "[WARN] models.dev fetch failed; rows without upstream cost keep cost=0" >&2
        : > "$PRICING_FILE"
    fi
else
    if [ ! -f "$PRICING_FILE" ]; then
        echo "[FAIL] pricing file not found: $PRICING_FILE" >&2
        exit 1
    fi
fi

if [ -s "$PRICING_FILE" ]; then
    jq -r '
        to_entries[] | .key as $p |
        (.value.models // {}) | to_entries[] | .key as $m |
        (.value.cost // {}) |
        [$p, ($m | ascii_downcase), (.input // 0), (.output // 0), (.cache_read // 0)] | @tsv
    ' "$PRICING_FILE" > "$TMPD/pricing.tsv"
else
    : > "$TMPD/pricing.tsv"
fi
echo "[INFO] pricing entries: $(wc -l < "$TMPD/pricing.tsv")" >&2

# ---------------------------------------------------------------- extract
# parts stream: message_id \t session_id \t part_tc_ms \t hex("type:text")
#               \t text_bytes   (all roles, ordered by message_id, part.id)
# messages: id, session_id, tc_ms, providerID, modelID, cost, input,
#   output, reasoning, cache_read, agent, project_id, parent_id, version, ts
: > "$TMPD/msg.tsv"
: > "$TMPD/hash.tsv"
: > "$TMPD/partstream.tsv"
: > "$TMPD/roles.tsv"
: > "$TMPD/usermark.tsv"
: > "$TMPD/firstpart.tsv"

extract_opencode_rows "$OPENCODE_DBS" "$TMPD"

EXTRACTED=$(wc -l < "$TMPD/msg.tsv")
echo "[INFO] extracted $EXTRACTED assistant message(s)" >&2
if [ "$EXTRACTED" -eq 0 ]; then
    echo "[OK] nothing to do"
    exit 0
fi

# ------------------------------------------------------------ join + map
# out fields: 1 msg_id 2 session_id 3 tc_ms 4 provider 5 model_raw
# 6 model_canon 7 cost 8 pt 9 ct 10 rt 11 cached 12 agent 13 project_id
# 14 parent_id 15 version 16 ts 17 content_hash 18 resp_bytes 19 error_name
# 20 completed_ms (timing; see row materialization below)
awk -F'\t' -v OFS='\t' '
    NR==FNR { alias[$2]=$1; next }
    FILENAME==ARGV[2] { hash[$1]=$2; bytes[$1]=$3; next }
    {
        m = tolower($5)
        if (m in alias) c = alias[m]
        else { seg=m; sub(/.*\//,"",seg); c = (seg in alias) ? alias[seg] : seg }
        print $1,$2,$3,$4,$5,c,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,hash[$1],bytes[$1]+0,$16,$17
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

# ------------------------------------- req_body synthesis inputs
# Per request: prior assistant-turn count (is_followup), last user prompt
# text, and prior marker texts (guard blocks / permission rejections).
# Same two-pointer shape as the sizes pass; replay-duplicate assistant
# messages (dropped by the natural-key dedup) are excluded here too.
LC_ALL=C sort -t $'\t' -k2,2 -k3,3n "$TMPD/roles.tsv" > "$TMPD/ro.sorted"
LC_ALL=C sort -t $'\t' -k2,2 -k3,3n "$TMPD/usermark.tsv" > "$TMPD/um.sorted"

awk -F'\t' -v OFS='\t' '
    NR==FNR { keep[$1]=1; next }
    FILENAME==ARGV[2] { if (!($1 in keep)) drop[$1]=1; next }
    FILENAME==ARGV[3] {
        if ($1 in drop) next
        np++; ps[np]=$2; pt[np]=$3+0; pr[np]=$4
        if (!($2 in start)) start[$2]=np
        next
    }
    {
        s=$2; mtc=$3+0
        i = (s in cur) ? cur[s] : (s in start ? start[s] : np+1)
        a = nasst[s]+0
        while (i <= np && ps[i] == s && pt[i] < mtc) {
            if (pr[i] == "assistant") a++
            i++
        }
        cur[s]=i; nasst[s]=a
        print $1, a
    }
' "$TMPD/dedup.tsv" "$TMPD/joined.tsv" "$TMPD/ro.sorted" "$TMPD/ds.sorted" > "$TMPD/rolecounts.tsv"

awk -F'\t' -v OFS='\t' '
    NR==FNR { keep[$1]=1; next }
    FILENAME==ARGV[2] { if (!($1 in keep)) drop[$1]=1; next }
    FILENAME==ARGV[3] {
        if ($1 in drop) next
        np++; ps[np]=$2; pt[np]=$3+0; pk[np]=$4; px[np]=$5
        if (!($2 in start)) start[$2]=np
        next
    }
    {
        s=$2; mtc=$3+0
        i = (s in cur) ? cur[s] : (s in start ? start[s] : np+1)
        lu = lastu[s]; mk = mks[s]
        while (i <= np && ps[i] == s && pt[i] < mtc) {
            if (pk[i] == "U") lu = px[i]
            else mk = (mk == "" ? "" : mk "\001") px[i]
            i++
        }
        cur[s]=i; lastu[s]=lu; mks[s]=mk
        print $1, lu, substr(mk, 1, 131072)
    }
' "$TMPD/dedup.tsv" "$TMPD/joined.tsv" "$TMPD/um.sorted" "$TMPD/ds.sorted" > "$TMPD/umcounts.tsv"

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
    awk -F'\t' -v shadow="$SHADOW_MAP" '
        BEGIN { n=split(shadow, pairs, ","); for (i=1;i<=n;i++) { split(pairs[i], kv, ":"); sh[kv[1]]=kv[2] } }
        NR==FNR { price[$1 ":" $2] = $3+$4+$5; next }
        ($7+0) == 0 {
            zero++
            m=tolower($5); k1=$4 ":" m; k2=$4 ":" $6
            if ((k1 in price && price[k1]>0) || (k2 in price && price[k2]>0)) res++
            else if (($4 in sh) && ((sh[$4] ":" m in price && price[sh[$4] ":" m]>0) || (sh[$4] ":" $6 in price && price[sh[$4] ":" $6]>0))) res++
        }
        END { printf "[DRY-RUN] rows with cost=0: %d; priced via models.dev: %d; unknown: %d\n", zero+0, res+0, zero-res }
    ' "$TMPD/pricing.tsv" "$TMPD/dedup.tsv"
    if curl -sSf --max-time 5 "$CH_URL/ping" 2>&1 | grep -q 'Ok.'; then
        EX_U=$(ch "SELECT count() FROM $DB.usage_log WHERE event_id LIKE 'ocm_%'")
        EX_R=$(ch "SELECT count() FROM $DB.request_log WHERE event_id LIKE 'ocr_%'")
        echo "[DRY-RUN] already present: usage_log=$EX_U request_log=$EX_R"
    else
        echo "[DRY-RUN] ClickHouse unreachable; existing-row counts not available"
    fi
    exit 0
fi

# ------------------------------------------------- rerun gate
# Stable event ids (ocm_<msgid> / ocr_<msgid>) mean a rerun over a
# populated target skips every existing row without notice, keeping stale cost
# and schema values. Requiring --force forces the operator through a
# backup + delete + verify-zero reset first.
EXISTING=$(ch "SELECT count() FROM $DB.usage_log WHERE event_id LIKE 'ocm_%'")
if [ "$EXISTING" -gt 0 ] && [ "$FORCE" != true ]; then
    echo "[FAIL] $EXISTING migrated row(s) already present in $DB.usage_log." >&2
    echo "       A rerun skips them (stable event ids) and keeps stale values." >&2
    echo "       Reset first (see SPEC-STATS-MIGRATION.md), verify the count is 0," >&2
    echo "       then rerun with --force and --backup-dir." >&2
    exit 1
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
                --user "$CH_OPS_USER:$CH_OPS_PASSWORD" \
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
#               duration_ms ttft_content_ms. Prompt INCLUDES cached,
#               completion INCLUDES reasoning (opencode stores disjoint).
# Timing (mirrors gateway sse-usage): duration_ms = time.completed -
# time_created; ttft_content_ms = first non-reasoning part - created;
# deltas outside [0, 1h) mean missing/corrupt timestamps -> 0.
awk -F'\t' -v OFS='\t' -v shadow="$SHADOW_MAP" '
    BEGIN {
        n=split(shadow, pairs, ",")
        for (i=1;i<=n;i++) { split(pairs[i], kv, ":"); sh[kv[1]]=kv[2] }
    }
    NR==FNR { price[$1 ":" $2] = $3 " " $4 " " $5; next }
    FILENAME==ARGV[2] { fp[$1]=$2; next }
    {
        cost = $7+0
        cs = (cost > 0) ? "upstream" : "unknown"
        if (cost == 0) {
            m = tolower($5)
            p = ""
            for (k in keys) delete keys[k]
            keys[1]=$4 ":" m; keys[2]=$4 ":" $6
            if ($4 in sh) { keys[3]=sh[$4] ":" m; keys[4]=sh[$4] ":" $6 }
            for (i=1;i<=4 && p=="";i++)
                if (keys[i] != "" && keys[i] in price) {
                    split(price[keys[i]], r, " ")
                    if (r[1]+r[2]+r[3] > 0) p = price[keys[i]]
                }
            if (p != "") {
                split(p, r, " ")
                cost = ($8*r[1] + $9*r[2] + $11*r[3] + $10*r[2]) / 1e6
                cs = "computed"
            }
        }
        pt = $8 + $11
        ct = $9 + $10
        ab = 0
        if ($19 == "MessageAbortedError") ab = 1
        else if ($19 == "APIError" || $19 == "UnknownError") ab = 2
        dur = ($20+0) - ($3+0)
        if (dur < 0 || dur >= 3600000) dur = 0
        ttft = (fp[$1]+0) - ($3+0)
        if (ttft < 0 || ttft >= 3600000) ttft = 0
        print "ocm_" $1, $1, $6, $5, pt, ct, pt+ct, $10+0, $11+0, \
              ab, 1, cost, cs, $4, $16, int(dur), int(ttft)
    }
' "$TMPD/pricing.tsv" "$TMPD/firstpart.tsv" "$TMPD/dedup.tsv" > "$TMPD/usage.tsv"

jq -cRn '
    inputs | split("\t") as $f |
    { event_id: $f[0], request_id: $f[1], model: $f[2], model_raw: $f[3],
      prompt_tokens: ($f[4]|tonumber), completion_tokens: ($f[5]|tonumber),
      total_tokens: ($f[6]|tonumber), cached_tokens: ($f[8]|tonumber),
      reasoning_tokens: ($f[7]|tonumber), aborted: ($f[9]|tonumber),
      is_stream: ($f[10]|tonumber), cost: ($f[11]|tonumber),
      cost_source: $f[12], provider_id: $f[13], timestamp: $f[14],
      duration_ms: ($f[15]|tonumber), ttft_content_ms: ($f[16]|tonumber) }
' "$TMPD/usage.tsv" > "$TMPD/usage.jsonl"

# request fields: event_id provider model model_raw session_id project_id
#                 parent_session_id agent_name opencode_version user_agent
#                 request_id ts request_size response_size n_asst_turns
#                 last_user_text marker_texts upstream_response_time_s
awk -F'\t' -v OFS='\t' '
    NR==FNR { rq[$1]=$2; rp[$1]=$3; next }
    FILENAME==ARGV[2] { na[$1]=$2; next }
    FILENAME==ARGV[3] { lu[$1]=$2; mk[$1]=$3; next }
    {
        dur = ($20+0) - ($3+0)
        if (dur < 0 || dur >= 3600000) dur = 0
        print "ocr_" $1, $4, $6, $5, $2, $13, $14, $12, $15, \
              "opencode/" $15, $1, $16, rq[$1]+0, rp[$1]+0, \
              na[$1]+0, lu[$1] "", mk[$1] "", sprintf("%.3f", dur / 1000)
    }
' "$TMPD/sizes.tsv" "$TMPD/rolecounts.tsv" "$TMPD/umcounts.tsv" "$TMPD/dedup.tsv" > "$TMPD/request.tsv"

jq -cRn '
    inputs | split("\t") as $f |
    { event_id: $f[0], provider: $f[1], model: $f[2], model_raw: $f[3],
      method: "POST", uri: "/v1/chat/completions", status: 200,
      stream: true, session_id: $f[4], project_id: $f[5],
      parent_session_id: $f[6], agent_name: $f[7],
      opencode_version: $f[8], user_agent: $f[9],
      request_id: $f[10], timestamp: $f[11],
      request_size: ($f[12]|tonumber), response_size: ($f[13]|tonumber),
      client_type: "migrated",
      upstream_response_time_s: ($f[17]|tonumber),
      req_body: ({
        model: $f[2],
        messages:
          ( [ range(0; ([($f[14]|tonumber), 200] | min))
              | {"role":"assistant","content":""} ]
            + [ ($f[15] | select(length > 0) | {"role":"user","content": .}) ]
            + [ ($f[16] | select(length > 0) | split("\u0001")[]
                  | {"role":"assistant","content": .}) ]
          )
      } | tojson) }
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
                | curl -sS --max-time 300 -X POST --user "$CH_OPS_USER:$CH_OPS_PASSWORD" "$CH_URL/" --data-binary @- \
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
