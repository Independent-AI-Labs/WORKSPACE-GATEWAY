#!/bin/bash
set -euo pipefail

# Structure tests for Dashboard: Gateway Model Performance
# (conf/grafana/dashboards/gateway-model-performance.json)
# Panels: prefill/decode speed (content-TTFT, p50), stream reliability
# (completed/cancel/abort), stream responsiveness (TTFT p50/p95 + goodput),
# wasted tokens & cost, completed-response cost/time.
# REQ-USEFULNESS-TELEMETRY FR-3/FR-6/FR-10.

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
    _SELF="$SHG_SCRIPT_PATH"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
source "$SCRIPT_DIR/dashboard_assert.sh" || exit 1

F="$PERFORMANCE_FILE"
LABEL="performance"

echo "=== Dashboard Structure Tests: Gateway Model Performance ==="
echo ""

[ -f "$F" ] || { echo "[FAIL] $LABEL missing: $F"; fail=$((fail+1)); summary "test_dashboard_performance.sh"; }

assert_json_valid "$LABEL: dashboard JSON is valid" "$F"

# Identity
assert_eq "$LABEL: title is Gateway Model Performance" "Gateway Model Performance" "$(jq -r '.title' "$F")"
assert_eq "$LABEL: uid is gateway-model-performance" "gateway-model-performance" "$(jq -r '.uid' "$F")"

# Panel inventory: 6 CH panels
assert_eq "$LABEL: panel count is 6" "6" "$(jq '.panels|length' "$F")"
assert_eq "$LABEL: panel ids" "30 31 36 44 45 48" "$(jq -r '[.panels[].id] | sort | map(tostring) | join(" ")' "$F")"
assert_eq "$LABEL: ClickHouse panels" "6" "$(jq '[.panels[]|select(.datasource.uid=="clickhouse")]|length' "$F")"
assert_eq "$LABEL: Prometheus panels" "0" "$(jq '[.panels[]|select(.datasource.uid=="prometheus")]|length' "$F")"

# Generic structural checks
check_dashboard_basics "$F" "$LABEL"

# Template variables: shared model + api_key only

# Every per-model rawSql gates on >= 100 responses and never scans req_body
GATED_PANELS=$(jq '[.panels[] | select((([.targets[].rawSql | test("count\\(\\) >= 100")]) | all) and ((.targets | length) > 0))] | length' "$F")
assert_eq "$LABEL: every panel query carries the >=100 relevance gate" "6" "$GATED_PANELS"
ALL_SQL=$(jq -r '[.panels[].targets[].rawSql] | join("\n")' "$F")
if printf '%s' "$ALL_SQL" | grep -q 'req_body'; then
    echo "[FAIL] $LABEL: rawSql references req_body (forbidden at refresh time)"; fail=$((fail+1))
else
    echo "[PASS] $LABEL: no rawSql references req_body"; pass=$((pass+1))
fi

# TTFT-derived speed panels (p30 prefill / p44 decode, split so the ~40k and
# ~100 scales never share an axis; single-frame long format, no refId prefixes)
P30_ALL_SQL=$(jq -r '[.panels[]|select(.id==30)][0] | [.targets[].rawSql] | join("\n")' "$F")
P44_ALL_SQL=$(jq -r '[.panels[]|select(.id==44)][0] | [.targets[].rawSql] | join("\n")' "$F")
printf '%s' "$P30_ALL_SQL" | grep -q 'nullIf(ttft_content_ms, 0)' && { echo "[PASS] $LABEL: p30 prefill guards zero TTFT"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p30 prefill missing nullIf guard"; fail=$((fail+1)); }
printf '%s' "$P44_ALL_SQL" | grep -q 'duration_ms - ttft_content_ms >= 100' && { echo "[PASS] $LABEL: p44 decode guards negative/degenerate windows (>=100ms)"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p44 decode missing duration guard"; fail=$((fail+1)); }
printf '%s' "$P30_ALL_SQL" | grep -q 'ttft_content_ms >= 100' && { echo "[PASS] $LABEL: p30 prefill floors degenerate TTFT (>=100ms)"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p30 missing prefill floor"; fail=$((fail+1)); }
printf '%s' "$P30_ALL_SQL" | grep -qF 'completion_tokens' && { echo "[FAIL] $LABEL: p30 must not mix decode series into the prefill panel"; fail=$((fail+1)); } || { echo "[PASS] $LABEL: p30 is prefill-only"; pass=$((pass+1)); }
printf '%s' "$P44_ALL_SQL" | grep -qF 'prompt_tokens /' && { echo "[FAIL] $LABEL: p44 must not mix prefill series into the decode panel"; fail=$((fail+1)); } || { echo "[PASS] $LABEL: p44 is decode-only"; pass=$((pass+1)); }
printf '%s' "$P30_ALL_SQL" | grep -q 'medianExactIf' && printf '%s' "$P44_ALL_SQL" | grep -q 'medianExactIf' && { echo "[PASS] $LABEL: p30/p44 are p50 (medianExactIf)"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p30/p44 missing p50"; fail=$((fail+1)); }
if printf '%s' "$P30_ALL_SQL$P44_ALL_SQL" | grep -qF "' (avg)'"; then
    echo "[FAIL] $LABEL: p30/p44 still carry the (avg) branch"; fail=$((fail+1))
else
    echo "[PASS] $LABEL: p30/p44 avg branch removed (p50 only)"; pass=$((pass+1))
fi
# count:tok/s scales K/M/B and keeps the unit word (77788.86 -> 77.79K tok/s)
assert_eq "$LABEL: p30 prefill abbreviates tok/s (count:tok/s)" "count:tok/s" "$(jq -r '[.panels[]|select(.id==30)][0].fieldConfig.defaults.unit' "$F")"
assert_eq "$LABEL: p44 decode abbreviates tok/s (count:tok/s)" "count:tok/s" "$(jq -r '[.panels[]|select(.id==44)][0].fieldConfig.defaults.unit' "$F")"

# p45: Cost & Time per Completed Response (standalone, explicitly averages)
P45_TYPE=$(jq -r '[.panels[]|select(.id==45)][0].type // "missing"' "$F")
assert_eq "$LABEL: p45 is stat panel" "stat" "$P45_TYPE"
P45_TITLE=$(jq -r '[.panels[]|select(.id==45)][0].title // "missing"' "$F")
assert_eq "$LABEL: p45 title marks averages" "Cost & Time per Completed Response (avg)" "$P45_TITLE"
P45_DESC=$(jq -r '[.panels[]|select(.id==45)][0].description // ""' "$F")
printf '%s' "$P45_DESC" | grep -qi 'NOT p50\|average' && { echo "[PASS] $LABEL: p45 declares averages (not p50)"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p45 missing avg annotation"; fail=$((fail+1)); }
P45_SQL=$(jq -r '[.panels[]|select(.id==45)][0].targets[0].rawSql // ""' "$F")
printf '%s' "$P45_SQL" | grep -q 'countIf(aborted = 0)' && printf '%s' "$P45_SQL" | grep -q 'avgIf(duration_ms' && { echo "[PASS] $LABEL: p45 averages cost + duration over completed streams"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p45 missing completed-stream averages"; fail=$((fail+1)); }

# Wasted tokens & cost (FR-10.4, revised 2026-09-17): % of total + $ value,
# compact B/M/K, and rejected tool calls counted as waste (tokens of the
# generation preceding a marker-bearing request in the same session)
P36_SQL=$(jq -r '[.panels[]|select(.id==36)][0].targets[].rawSql' "$F")
printf '%s' "$P36_SQL" | grep -qF 'nullIf(total_tokens, 0)' && printf '%s' "$P36_SQL" | grep -qF "wasted_tokens + rej_wasted" && { echo "[PASS] $LABEL: p36 shows wasted tokens as % of total"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p36 missing % of total"; fail=$((fail+1)); }
printf '%s' "$P36_SQL" | grep -qF 'sumIf(cost, aborted > 0)' && { echo "[PASS] $LABEL: p36 puts a $ value on wasted tokens"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p36 missing wasted cost"; fail=$((fail+1)); }
printf '%s' "$P36_SQL" | grep -qF ", 'B')" && printf '%s' "$P36_SQL" | grep -qF ", 'M')" && printf '%s' "$P36_SQL" | grep -qF ", 'K')" && { echo "[PASS] $LABEL: p36 wasted tokens use compact B/M/K"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p36 missing B/M/K formatting"; fail=$((fail+1)); }
printf '%s' "$P36_SQL" | grep -qF 'lagInFrame' && printf '%s' "$P36_SQL" | grep -qF 's.user_rejections + s.rule_denials + s.guard_blocks' && { echo "[PASS] $LABEL: p36 counts rejected tool-call tokens (prev generation via lagInFrame)"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p36 missing rejected-tool waste"; fail=$((fail+1)); }
printf '%s' "$P36_SQL" | grep -qF 'rej > 0 AND prev_ab = 0' && { echo "[PASS] $LABEL: p36 never double-counts an aborted generation"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p36 may double-count aborted + rejected"; fail=$((fail+1)); }
printf '%s' "$P36_SQL" | grep -qF 'sumIf(prev_cost, rej > 0 AND prev_ab = 0)' && printf '%s' "$P36_SQL" | grep -qF 'wasted_cost + rej_cost' && { echo "[PASS] $LABEL: p36 waste cost covers rejected tool calls (consistent with token count)"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p36 waste cost inconsistent with waste tokens"; fail=$((fail+1)); }
if printf '%s' "$P36_SQL" | grep -qF 'Cost per Completed Response'; then
    echo "[FAIL] $LABEL: p36 still carries the completed-response cost (moved to p45)"; fail=$((fail+1))
else
    echo "[PASS] $LABEL: p45 owns the completed-response cost"; pass=$((pass+1))
fi
printf '%s' "$P36_SQL" | grep -qF "concat('$'" && { echo "[PASS] $LABEL: p36 renders exact dollar values ($, forced 2 decimals)"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p36 missing dollar formatting"; fail=$((fail+1)); }
printf '%s' "$P45_SQL" | grep -qF "n >= 1000, concat(toString(round(n / 1000, 2)), 'K')" && { echo "[PASS] $LABEL: p45 abbreviates completed-response count (B/M/K, rounded)"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p45 missing count abbreviation"; fail=$((fail+1)); }

# Stream reliability (p31): completed + cancel + abort as shares of streams
P31_ALL_SQL=$(jq -r '[.panels[]|select(.id==31)][0] | [.targets[].rawSql] | join("\n")' "$F")
printf '%s' "$P31_ALL_SQL" | grep -qF 'aborted = 0 AND is_stream = 1' && { echo "[PASS] $LABEL: p31 completed rate excludes non-stream rows"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p31 completed numerator must AND is_stream = 1"; fail=$((fail+1)); }
printf '%s' "$P31_ALL_SQL" | grep -qF 'countIf(is_stream = 1)' && { echo "[PASS] $LABEL: p31 shares use the stream cohort as denominator"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p31 missing stream denominator"; fail=$((fail+1)); }

# Stream responsiveness (p48): TTFT p50/p95 + goodput within 2s
P48_ALL_SQL=$(jq -r '[.panels[]|select(.id==48)][0] | [.targets[].rawSql] | join("\n")' "$F")
printf '%s' "$P48_ALL_SQL" | grep -qF 'quantile(0.5)(ttft_content_ms)' && printf '%s' "$P48_ALL_SQL" | grep -qF 'quantile(0.95)(ttft_content_ms)' && { echo "[PASS] $LABEL: p48 shows TTFT p50 + p95"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p48 missing TTFT percentiles"; fail=$((fail+1)); }
printf '%s' "$P48_ALL_SQL" | grep -qF 'ttft_content_ms <= 2000' && { echo "[PASS] $LABEL: p48 goodput counts streams starting within 2s"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p48 missing 2s goodput"; fail=$((fail+1)); }
printf '%s' "$P48_ALL_SQL" | grep -qF 'ttft_content_ms > 0' && { echo "[PASS] $LABEL: p48 excludes streams with no recorded TTFT"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p48 must exclude zero-TTFT rows"; fail=$((fail+1)); }
assert_eq "$LABEL: p48 goodput rendered as percent" "percent" "$(jq -r '[.panels[]|select(.id==48)][0].fieldConfig.overrides[]|select(.matcher.options=="Goodput <=2s (%)")|.properties[]|select(.id=="unit")|.value' "$F")"

# Readable display names (FR-10.5): no raw refId/column identifiers on stats
P31_NAMES=$(jq -c '[.panels[]|select(.id==31)][0].fieldConfig.overrides[].properties[]|select(.id=="displayName")|.value' "$F")
printf '%s' "$P31_NAMES" | grep -qF 'Client Cancel Rate' && printf '%s' "$P31_NAMES" | grep -qF 'Provider Abort Rate' && printf '%s' "$P31_NAMES" | grep -qF 'Completed Rate' && { echo "[PASS] $LABEL: p31 series carry human-readable display names"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p31 missing readable display names"; fail=$((fail+1)); }

# Grouping (FR-10.6): speeds, then reliability/responsiveness, waste/cost
assert_eq "$LABEL: panels grouped top-to-bottom" "30 44 31 48 36 45" "$(jq -r '[.panels[].id] | map(tostring) | join(" ")' "$F")"

# Row-keyed bargauges show one gauge per row; bars compare from zero
assert_eq "$LABEL: bargauge panels use all-values reduce" "2/2" "$(jq -r '[.panels[]|select(.type=="bargauge")]|"\([.[]|select(.options.reduceOptions.values==true)]|length)/\(length)"' "$F")"
assert_eq "$LABEL: bargauge bars are zero-based" "2/2" "$(jq -r '[.panels[]|select(.type=="bargauge")]|"\([.[]|select(.fieldConfig.defaults.min==0)]|length)/\(length)"' "$F")"

# Cross-dashboard invariant: shared api_key + model templating identical
check_templating_sync

summary "test_dashboard_performance.sh"
