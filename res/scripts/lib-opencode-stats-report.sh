#!/usr/bin/env bash
# lib-opencode-stats-report.sh - dry-run report and batched insert helpers for
# migrate-opencode-stats.sh. Sourced by that script after the extract lib.

# opencode_stats_dry_run_report: print planned insert counts, price coverage,
# and a row-by-row diff against any migrated rows already in ClickHouse.
opencode_stats_dry_run_report() {
    echo "[DRY-RUN] rows to insert: usage_log=$KEPT request_log=$KEPT"
    echo "[DRY-RUN] source duplicates collapsed: $DUPES"
    echo "[DRY-RUN] TTL-expired rows: $TTL_EXPIRED"
    awk -F'\t' '
        NR==FNR { gw_mdev[$1]=$4; next }
        FILENAME==ARGV[2] { dm[$1]=$2; next }
        FILENAME==ARGV[3] { if ($3+0 > 0) ok[$1 ":" $2]=1; next }
        {
            mdev = ($21 in gw_mdev) ? gw_mdev[$21] : (($21 in dm) ? dm[$21] : $21)
            if ((mdev ":" $6) in ok) res++
            else unpriced++
        }
        END { printf "[DRY-RUN] rows priced via models.dev: %d; unknown: %d\n", res+0, unpriced+0 }
    ' "$TMPD/gateway_providers.tsv" "$TMPD/direct_pricing.tsv" "$TMPD/pricing.tsv" "$TMPD/dedup.tsv"
    if curl -sSf --max-time 5 "$CH_URL/ping" 2>&1 | grep -q 'Ok.'; then
        EX_U=$(ch "$(sql_render ops/migrate-opencode-stats/count-prefixed.sql DB="$DB" TABLE=usage_log PREFIX=ocm_)")
        EX_R=$(ch "$(sql_render ops/migrate-opencode-stats/count-prefixed.sql DB="$DB" TABLE=request_log PREFIX=ocr_)")
        echo "[DRY-RUN] already present: usage_log=$EX_U request_log=$EX_R"
        ch "$(sql_render ops/migrate-opencode-stats/usage-dump.sql DB="$DB" PREFIX=ocm_)" \
            > "$TMPD/ch_usage.tsv"
        awk -F'\t' '
            NR==FNR {
                id=$1
                c_model[id]=$3; c_raw[id]=$4; c_pid[id]=$14; c_pt[id]=$5
                c_ct[id]=$6; c_tt[id]=$7; c_rt[id]=$8; c_ca[id]=$9
                c_cw[id]=$18; c_cost[id]=$12; c_cs[id]=$13; c_rep[id]=$19
                c_ts[id]=$15; c_dur[id]=$16; c_ttft[id]=$17
                next
            }
            {
                id=$1
                if (!(id in c_model)) { extra++; next }
                seen[id]=1
                d=0
                if ($2 != c_model[id]) { d=1; f["model"]++ }
                if ($3 != c_raw[id]) { d=1; f["model_raw"]++ }
                if ($4 != c_pid[id]) { d=1; f["provider_id"]++ }
                if ($5 != c_pt[id]) { d=1; f["prompt_tokens"]++ }
                if ($6 != c_ct[id]) { d=1; f["completion_tokens"]++ }
                if ($7 != c_tt[id]) { d=1; f["total_tokens"]++ }
                if ($8 != c_ca[id]) { d=1; f["cached_tokens"]++ }
                if ($9 != c_cw[id]) { d=1; f["cache_write_tokens"]++ }
                if ($10 != c_rt[id]) { d=1; f["reasoning_tokens"]++ }
                if (($11 - c_cost[id] > 1e-9) || (c_cost[id] - $11 > 1e-9)) { d=1; f["cost"]++ }
                if ($12 != c_cs[id]) { d=1; f["cost_source"]++ }
                if (($13 - c_rep[id] > 1e-9) || (c_rep[id] - $13 > 1e-9)) { d=1; f["reported_cost"]++ }
                if ($14 != c_ts[id]) { d=1; f["timestamp"]++ }
                if ($15 != c_dur[id]) { d=1; f["duration_ms"]++ }
                if ($16 != c_ttft[id]) { d=1; f["ttft_content_ms"]++ }
                if (d) {
                    diff++
                    if (diff <= 5) printf "[DRY-RUN]   differs %s model=%s/%s provider=%s/%s cost=%s/%s source=%s/%s\n", id, $2, c_model[id], $4, c_pid[id], $11, c_cost[id], $12, c_cs[id]
                }
            }
            END {
                for (id in c_model) if (!(id in seen)) missing++
                printf "[DRY-RUN] diff vs ClickHouse: missing=%d differing=%d extra=%d\n", missing+0, diff+0, extra+0
                printf "[DRY-RUN] differing fields:"
                for (k in f) printf " %s=%d", k, f[k]
                printf "\n"
            }
        ' "$TMPD/usage.tsv" "$TMPD/ch_usage.tsv"
    else
        echo "[DRY-RUN] ClickHouse unreachable; existing-row counts not available"
    fi
}

# insert_table <table> <jsonl>: insert only event_ids not already present, in
# BATCH_SIZE batches, reporting inserted and skipped counts.
insert_table() {
    local table="$1" jsonl="$2"
    local total inserted=0 skipped=0
    total=$(wc -l < "$jsonl")
    split -l "$BATCH_SIZE" "$jsonl" "$TMPD/batch_"
    for b in "$TMPD"/batch_*; do
        [ -s "$b" ] || continue
        local ids exist keep
        ids=$(jq -r '.event_id' "$b" | awk 'BEGIN{q="\x27"} {printf "%s", (NR>1?",":"") q $0 q}')
        exist=$(ch "$(sql_render ops/migrate-opencode-stats/existing-ids.sql DB="$DB" TABLE="$table" IDS="$ids")")
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
            if ! code=$({ sql_render ops/migrate-opencode-stats/insert-json-each-row.sql DB="$DB" TABLE="$table"; cat "$TMPD/keep.jsonl"; } \
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
    mark "insert-$table"
    echo "[OK] $table: inserted=$inserted skipped_existing=$skipped of $total"
}
