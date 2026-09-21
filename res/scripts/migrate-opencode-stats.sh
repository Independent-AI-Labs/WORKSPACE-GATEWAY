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
if ! source "$REPO_ROOT/res/scripts/lib-opencode-stats-report.sh"; then
    echo "[FAIL] cannot source lib-opencode-stats-report.sh from $REPO_ROOT" >&2
    exit 1
fi
export REPO_ROOT
# shellcheck source=/dev/null
source "$REPO_ROOT/res/scripts/lib-sql.sh" || exit 1

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

# Stage timing to stderr: identifies hot spots on the multi-GB real DB
# (dry-run output on stdout is untouched).
_MARK_T=$(date +%s%3N)
mark() {
    local n
    n=$(date +%s%3N)
    echo "[TIME] $1 $((n - _MARK_T))ms" >&2
    _MARK_T=$n
}

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

# ------------------------------------------------------- provider aliases
# Prior provider ids -> canonical gateway id, parsed from cost_calc.lua
# (single source of truth). Ids that are neither canonical nor a known
# alias stay verbatim; no other provider is consulted.
awk '
  /^M\.PROVIDER_ALIASES = \{/ { inb=1; next }
  inb && /^\}/ { inb=0 }
  inb {
    if (match($0, /\["[^"]+"\] *= *"[^"]+"/)) {
      s=substr($0,RSTART,RLENGTH)
      gsub(/[]["]/,"",s)
      sub(/ *= */,"\t",s)
      print s
    }
  }
' "$REPO_ROOT/plugins/custom/cost_calc.lua" > "$TMPD/provider_aliases.tsv"

# ------------------------------------------- gateway provider declarations
# Each gateway provider declares its models.dev cost provider and its HTTP
# route in conf/providers/*.yaml (pricing.source.type/provider, route).
# This is the ONLY mapping from a gateway provider id to its cost provider;
# there is no cross-provider or cheapest-wins merge.
#   gateway_id \t route \t pricing_type \t models_dev_provider
: > "$TMPD/gateway_providers.tsv"
for f in "$REPO_ROOT"/conf/providers/*.yaml; do
    awk -v OFS='\t' '
        /^id:/      { id=$2 }
        /^route:/   { r=$2; gsub(/"/,"",r); route=r }
        /^pricing:/ { p=1; next }
        p && /^  source:/ { s=1; next }
        s && /^    type:/     { t=$2 }
        s && /^    provider:/ { v=$2 }
        p && /^[^ ]/ && !/^pricing:/ { p=0; s=0 }
        END { printf "%s\t%s\t%s\t%s\n", id, route, t, v }
    ' "$f" >> "$TMPD/gateway_providers.tsv"
done

# Historical direct (non-gateway) providers priced at an equivalent
# models.dev provider. Explicit and reviewable, never inferred:
#   zai-coding-plan publishes only zero rates on models.dev (flat-fee
#   plan), so it is priced at the PAYG-equivalent provider zai.
printf 'zai-coding-plan\tzai\n' > "$TMPD/direct_pricing.tsv"

# ---------------------------------------------------------------- pricing
# models.dev per-1M-token rates, flattened to:
#   models_dev_provider \t model(lower) \t input \t output \t cache_read \t
#   cache_write \t reasoning
# A row's cost provider is its gateway id's declared models.dev provider
# (above) when it is a gateway provider, else the historical providerID
# itself (opencode's direct providers are models.dev provider ids). Ids with
# no models.dev entry (e.g. workspace-gateway) stay unpriced.
if [ -z "$PRICING_FILE" ]; then
    PRICING_FILE="$TMPD/modelsdev.json"
    if ! curl -sSf --max-time 60 -o "$PRICING_FILE" "$MODELS_DEV_URL"; then
        echo "[FAIL] models.dev fetch failed ($MODELS_DEV_URL); use --pricing-file offline" >&2
        exit 1
    fi
elif [ ! -f "$PRICING_FILE" ]; then
    echo "[FAIL] pricing file not found: $PRICING_FILE" >&2
    exit 1
fi

jq -r '
    to_entries[] | .key as $p |
    (.value.models // {}) | to_entries[] | .key as $m |
    (.value.cost // {}) |
    [$p, ($m | ascii_downcase), (.input // 0), (.output // 0),
     (.cache_read // 0), (.cache_write // 0), (.reasoning // 0)] | @tsv
' "$PRICING_FILE" > "$TMPD/pricing.tsv"
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

mark "extract"
EXTRACTED=$(wc -l < "$TMPD/msg.tsv")
echo "[INFO] extracted $EXTRACTED assistant message(s)" >&2
if [ "$EXTRACTED" -eq 0 ]; then
    echo "[OK] nothing to do"
    exit 0
fi

# ------------------------------------------------------------ join + map
# out fields: 1 msg_id 2 session_id 3 tc_ms 4 provider_raw 5 model_raw
# 6 model_canon 7 cost 8 input 9 output 10 reasoning 11 cached 12 agent
# 13 project_id 14 parent_id 15 version 16 ts 17 content_hash 18 resp_bytes
# 19 error_name 20 completed_ms 21 provider_canon 22 cache_write
# (timing/provenance; see row materialization below)
awk -F'\t' -v OFS='\t' '
    NR==FNR { alias[$2]=$1; next }
    FILENAME==ARGV[2] { palias[$1]=$2; next }
    FILENAME==ARGV[3] { hash[$1]=$2; bytes[$1]=$3; next }
    {
        m = tolower($5)
        if (m in alias) c = alias[m]
        else { seg=m; sub(/.*\//,"",seg); c = (seg in alias) ? alias[seg] : seg }
        pp = ($4 in palias) ? palias[$4] : $4
        print $1,$2,$3,$4,$5,c,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,hash[$1],bytes[$1]+0,$16,$17,pp,$18
    }
' "$TMPD/aliases.tsv" "$TMPD/provider_aliases.tsv" "$TMPD/hash.tsv" "$TMPD/msg.tsv" > "$TMPD/joined.tsv"

mark "join"

# ------------------------------------------------- natural-key dedup
# key: session_id, provider, model_raw, tc, content_hash ; keep min msg_id
sort -t $'\t' -k2,2 -k4,4 -k5,5 -k3,3n -k17,17 -k1,1 "$TMPD/joined.tsv" \
 | awk -F'\t' '{
     k=$2 FS $4 FS $5 FS $3 FS $17
     if (!(k in seen)) { seen[k]=1; print }
   }' > "$TMPD/dedup.tsv"

mark "dedup"

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

mark "sizes"

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

mark "rolecounts"

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

mark "umcounts"

KEPT=$(wc -l < "$TMPD/dedup.tsv")
DUPES=$((EXTRACTED - KEPT))
echo "[INFO] source duplicates collapsed: $DUPES; to migrate: $KEPT" >&2

TTL_EXPIRED=$(awk -F'\t' -v cutoff="$(( $(date +%s) - 397*86400 ))" \
    '$3 < cutoff*1000 {n++} END{print n+0}' "$TMPD/dedup.tsv")
[ "$TTL_EXPIRED" -gt 0 ] && \
    echo "[WARN] $TTL_EXPIRED row(s) older than 13-month TTL will be expired by ClickHouse" >&2

# ------------------------------------------------- row materialization
# usage fields: event_id request_id model model_raw pt ct tt rt cached
#               aborted is_stream cost cost_source provider_id ts
#               duration_ms ttft_content_ms cache_write reported_cost.
# Prompt INCLUDES cached + cache_write; completion INCLUDES reasoning
# (opencode stores disjoint). Billed cost is ALWAYS the provider-scoped
# models.dev price: gateway ids use their declared
# pricing.source.provider, direct providers use their own id as the
# models.dev namespace. The opencode-recorded cost is metadata and is
# persisted verbatim as reported_cost - it never sets billed cost. A row
# whose provider has no models.dev price is 0/unknown. Key is
# models_dev_provider : canonical(model), mirroring cost_calc.compute_cost.
# Timing (mirrors gateway sse-usage): duration_ms = time.completed -
# time_created; ttft_content_ms = first non-reasoning part - created;
# deltas outside [0, 1h) mean missing/corrupt timestamps -> 0.
awk -F'\t' -v OFS='\t' '
    NR==FNR { gw_mdev[$1]=$4; next }
    FILENAME==ARGV[2] { dm[$1]=$2; next }
    FILENAME==ARGV[3] {
        k=$1 ":" $2
        r_input[k]=$3+0; r_output[k]=$4+0; r_cread[k]=$5+0
        r_cwrite[k]=$6+0; r_reason[k]=$7+0
        if ($3+0 > 0) priced[k]=1
        next
    }
    FILENAME==ARGV[4] { fp[$1]=$2; next }
    {
        reported = $7+0
        cost = 0
        cs = "unknown"
        cw = $22+0
        mdev = ($21 in gw_mdev) ? gw_mdev[$21] : (($21 in dm) ? dm[$21] : $21)
        k = mdev ":" $6
        if (k in priced) {
            ir=r_input[k]; orr=r_output[k]
            iu = ($8+$11+cw) - $11 - cw
            if (iu < 0) iu = 0
            onr = ($9+$10) - $10
            if (onr < 0) onr = ($9+$10)
            # Mirror provider_sync_pricing: a reasoning rate is published
            # only when the catalog has one, so a missing/zero rate falls
            # back to the output rate (never billed as free).
            rr = (r_reason[k]+0 > 0) ? r_reason[k] : orr
            # Mirror provider_sync_pricing: a nil or non-positive cache rate
            # bills at the input rate, never free.
            cr = (r_cread[k]+0 > 0) ? r_cread[k] : ir
            cwr = (r_cwrite[k]+0 > 0) ? r_cwrite[k] : ir
            cost = (iu*ir + onr*orr + $11*cr \
                    + cw*cwr + $10*rr) / 1e6
            cs = "models_dev"
        }
        pt = $8 + $11 + cw
        ct = $9 + $10
        ab = 0
        if ($19 == "MessageAbortedError") ab = 1
        else if ($19 == "APIError" || $19 == "UnknownError") ab = 2
        dur = ($20+0) - ($3+0)
        if (dur < 0 || dur >= 3600000) dur = 0
        ttft = (fp[$1]+0) - ($3+0)
        if (ttft < 0 || ttft >= 3600000) ttft = 0
        print "ocm_" $1, $1, $6, $5, pt, ct, pt+ct, $10+0, $11+0, \
              ab, 1, cost, cs, $21, $16, int(dur), int(ttft), cw, reported
    }
' "$TMPD/gateway_providers.tsv" "$TMPD/direct_pricing.tsv" "$TMPD/pricing.tsv" "$TMPD/firstpart.tsv" "$TMPD/dedup.tsv" > "$TMPD/usage.tsv"

jq -cRn '
    inputs | split("\t") as $f |
    { event_id: $f[0], request_id: $f[1], model: $f[2], model_raw: $f[3],
      prompt_tokens: ($f[4]|tonumber), completion_tokens: ($f[5]|tonumber),
      total_tokens: ($f[6]|tonumber), cached_tokens: ($f[8]|tonumber),
      cache_write_tokens: ($f[17]|tonumber),
      reasoning_tokens: ($f[7]|tonumber), aborted: ($f[9]|tonumber),
      is_stream: ($f[10]|tonumber), cost: ($f[11]|tonumber),
      cost_source: $f[12], reported_cost: ($f[18]|tonumber),
      provider_id: $f[13], timestamp: $f[14],
      duration_ms: ($f[15]|tonumber), ttft_content_ms: ($f[16]|tonumber) }
' "$TMPD/usage.tsv" > "$TMPD/usage.jsonl"

mark "usage-json"

# request fields: event_id provider(canonical) model model_raw session_id
#                 project_id parent_session_id agent_name opencode_version
#                 user_agent request_id ts request_size response_size
#                 n_asst_turns last_user_text marker_texts
#                 upstream_response_time_s uri
# uri is synthesized from the provider's declared gateway route (the path
# the request would have taken); non-gateway providers keep the plain
# /v1/chat/completions path.
awk -F'\t' -v OFS='\t' '
    NR==FNR { route[$1]=$2; next }
    FILENAME==ARGV[2] { rq[$1]=$2; rp[$1]=$3; next }
    FILENAME==ARGV[3] { na[$1]=$2; next }
    FILENAME==ARGV[4] { lu[$1]=$2; mk[$1]=$3; next }
    {
        dur = ($20+0) - ($3+0)
        if (dur < 0 || dur >= 3600000) dur = 0
        uri = (($21 in route) && route[$21] != "") ? route[$21] "/chat/completions" : "/v1/chat/completions"
        print "ocr_" $1, $21, $6, $5, $2, $13, $14, $12, $15, \
              "opencode/" $15, $1, $16, rq[$1]+0, rp[$1]+0, \
              na[$1]+0, lu[$1] "", mk[$1] "", sprintf("%.3f", dur / 1000), uri
    }
' "$TMPD/gateway_providers.tsv" "$TMPD/sizes.tsv" "$TMPD/rolecounts.tsv" "$TMPD/umcounts.tsv" "$TMPD/dedup.tsv" > "$TMPD/request.tsv"

jq -cRn '
    inputs | split("\t") as $f |
    { event_id: $f[0], provider: $f[1], model: $f[2], model_raw: $f[3],
      method: "POST", uri: $f[18], status: 200,
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

mark "request-json"

# ------------------------------------------------- dry-run report
if [ "$DRY_RUN" = true ]; then
    opencode_stats_dry_run_report
    exit 0
fi

# ------------------------------------------------- rerun gate
# Stable event ids (ocm_<msgid> / ocr_<msgid>) mean a rerun over a
# populated target skips every existing row without notice, keeping stale cost
# and schema values. Requiring --force forces the operator through a
# backup + delete + verify-zero reset first.
EXISTING=$(ch "$(sql_render ops/migrate-opencode-stats/count-prefixed.sql DB="$DB" TABLE=usage_log PREFIX=ocm_)")
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
        cnt=$(ch "$(sql_render ops/migrate-opencode-stats/table-count.sql DB="$DB" TABLE="$t")")
        cks=$(ch "$(sql_render ops/migrate-opencode-stats/table-checksum.sql DB="$DB" TABLE="$t")")
        printf '%s\trows=%s\tcityHash64sum=%s\n' "$t" "$cnt" "$cks" \
            >> "$BACKUP_DIR/manifest.txt"
        if ! curl -sS --max-time 600 -o "$BACKUP_DIR/$t.native" \
                --user "$CH_OPS_USER:$CH_OPS_PASSWORD" \
                "$CH_URL/" --data-binary "$(sql_render ops/migrate-opencode-stats/table-native-dump.sql DB="$DB" TABLE="$t")"; then
            echo "[FAIL] backup dump of $t failed" >&2
            exit 1
        fi
    done
    echo "[OK] backup complete: $BACKUP_DIR" >&2
fi

# ------------------------------------------------- batched insert
insert_table usage_log "$TMPD/usage.jsonl"
insert_table request_log "$TMPD/request.jsonl"
echo "[OK] migration complete"
