#!/bin/bash
set -euo pipefail

# Structure tests for Dashboard: Gateway Model Performance
# (conf/grafana/dashboards/gateway-model-performance.json)
# Panels: prefill/decode speed (content-TTFT, avg + p50), cancel/abort rate,
# wasted tokens & cost, historical decode proxy (estimate).
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

# Panel inventory: 5 CH panels
assert_eq "$LABEL: panel count is 5" "5" "$(jq '.panels|length' "$F")"
assert_eq "$LABEL: panel ids" "30 31 36 39 44" "$(jq -r '[.panels[].id] | sort | map(tostring) | join(" ")' "$F")"
assert_eq "$LABEL: ClickHouse panels" "5" "$(jq '[.panels[]|select(.datasource.uid=="clickhouse")]|length' "$F")"
assert_eq "$LABEL: Prometheus panels" "0" "$(jq '[.panels[]|select(.datasource.uid=="prometheus")]|length' "$F")"

# Generic structural checks
check_dashboard_basics "$F" "$LABEL"

# Template variables: shared model + api_key only (no rejection_mode here)
RM_PRESENT=$(jq '[.templating.list[]|select(.name=="rejection_mode")]|length' "$F")
assert_eq "$LABEL: no rejection_mode variable on performance" "0" "$RM_PRESENT"

# Every per-model rawSql gates on >= 100 responses and never scans req_body
GATED_PANELS=$(jq '[.panels[] | select((([.targets[].rawSql | test("count\\(\\) >= 100")]) | all) and ((.targets | length) > 0))] | length' "$F")
assert_eq "$LABEL: every panel query carries the >=100 relevance gate" "5" "$GATED_PANELS"
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
printf '%s' "$P30_ALL_SQL" | grep -q 'medianExactIf' && printf '%s' "$P44_ALL_SQL" | grep -q 'medianExactIf' && { echo "[PASS] $LABEL: p30/p44 carry p50 companions (medianExactIf)"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p30/p44 missing p50 targets"; fail=$((fail+1)); }

# Historical proxy is labeled as an estimate
P39_DESC=$(jq -r '[.panels[]|select(.id==39)][0].description' "$F")
printf '%s' "$P39_DESC" | grep -qi 'estimate' && { echo "[PASS] $LABEL: p39 proxy labeled ESTIMATE"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p39 missing ESTIMATE label"; fail=$((fail+1)); }

# Wasted tokens & cost (FR-10.4): % of total + $ value, exact strings
P36_SQL=$(jq -r '[.panels[]|select(.id==36)][0].targets[].rawSql' "$F")
printf '%s' "$P36_SQL" | grep -qF '100 * wasted_tokens / nullIf(total_tokens, 0)' && { echo "[PASS] $LABEL: p36 shows wasted tokens as % of total"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p36 missing % of total"; fail=$((fail+1)); }
printf '%s' "$P36_SQL" | grep -qF 'sumIf(cost, aborted > 0)' && { echo "[PASS] $LABEL: p36 puts a $ value on wasted tokens"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p36 missing wasted cost"; fail=$((fail+1)); }
printf '%s' "$P36_SQL" | grep -qF "concat('$'" && { echo "[PASS] $LABEL: p36 renders exact dollar values ($, forced 2 decimals)"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p36 missing dollar formatting"; fail=$((fail+1)); }

# Readable display names (FR-10.5): no raw refId/column identifiers on stats
P31_NAMES=$(jq -c '[.panels[]|select(.id==31)][0].fieldConfig.overrides[].properties[]|select(.id=="displayName")|.value' "$F")
printf '%s' "$P31_NAMES" | grep -qF 'Client Cancel Rate (%)' && printf '%s' "$P31_NAMES" | grep -qF 'Provider Abort Rate (%)' && { echo "[PASS] $LABEL: p31 series carry human-readable display names"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p31 missing readable display names"; fail=$((fail+1)); }

# Grouping (FR-10.6): speeds first, then reliability/waste/proxy
assert_eq "$LABEL: panels grouped top-to-bottom" "30 44 31 36 39" "$(jq -r '[.panels[].id] | map(tostring) | join(" ")' "$F")"

# Row-keyed bargauges show one gauge per row; bars compare from zero
assert_eq "$LABEL: bargauge panels use all-values reduce" "2/2" "$(jq -r '[.panels[]|select(.type=="bargauge")]|"\([.[]|select(.options.reduceOptions.values==true)]|length)/\(length)"' "$F")"
assert_eq "$LABEL: bargauge bars are zero-based" "2/2" "$(jq -r '[.panels[]|select(.type=="bargauge")]|"\([.[]|select(.fieldConfig.defaults.min==0)]|length)/\(length)"' "$F")"

# Cross-dashboard invariant: shared api_key + model templating identical
check_templating_sync

summary "test_dashboard_performance.sh"
