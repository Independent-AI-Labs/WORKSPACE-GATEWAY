#!/bin/bash
set -euo pipefail

# Structure tests for Dashboard: Gateway Model Experience
# (conf/grafana/dashboards/gateway-model-experience.json)
# Panels: score leaderboard + scorecard, rejection rate/baseline/net,
# signals over time, top rejection strings, session depth, model switch,
# friction rate, top guard rules.
# REQ-USEFULNESS-TELEMETRY FR-6/FR-8/FR-9/FR-10.

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
    _SELF="$SHG_SCRIPT_PATH"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
source "$SCRIPT_DIR/dashboard_assert.sh" || exit 1

F="$EXPERIENCE_FILE"
LABEL="experience"

echo "=== Dashboard Structure Tests: Gateway Model Experience ==="
echo ""

[ -f "$F" ] || { echo "[FAIL] $LABEL missing: $F"; fail=$((fail+1)); summary "test_dashboard_experience.sh"; }

assert_json_valid "$LABEL: dashboard JSON is valid" "$F"

# Identity
assert_eq "$LABEL: title is Gateway Model Experience" "Gateway Model Experience" "$(jq -r '.title' "$F")"
assert_eq "$LABEL: uid is gateway-model-experience" "gateway-model-experience" "$(jq -r '.uid' "$F")"

# Panel inventory: 10 CH panels
assert_eq "$LABEL: panel count is 10" "10" "$(jq '.panels|length' "$F")"
assert_eq "$LABEL: panel ids" "32 33 34 35 37 38 40 41 42 43" "$(jq -r '[.panels[].id] | sort | map(tostring) | join(" ")' "$F")"
assert_eq "$LABEL: ClickHouse panels" "10" "$(jq '[.panels[]|select(.datasource.uid=="clickhouse")]|length' "$F")"
assert_eq "$LABEL: Prometheus panels" "0" "$(jq '[.panels[]|select(.datasource.uid=="prometheus")]|length' "$F")"

# Generic structural checks (title/type/datasource/gridPos/target, refId,
# rawSql, brand palette, 90d/5s, no meta keys, formats, single-target tiles)
check_dashboard_basics "$F" "$LABEL"

# Template variables: model + api_key shared, plus dashboard-local rejection_mode
RM_TYPE=$(jq -r '[.templating.list[]|select(.name=="rejection_mode")]|if length==0 then "missing" else (.[0].type) end' "$F")
assert_eq "$LABEL: rejection_mode variable exists" "custom" "$RM_TYPE"
RM_CURRENT=$(jq -r '.templating.list[]|select(.name=="rejection_mode")|.current.value' "$F")
assert_eq "$LABEL: rejection_mode default is binary" "binary" "$RM_CURRENT"
RM_VALUES=$(jq -r '[.templating.list[]|select(.name=="rejection_mode")|.options[].value] | sort | join(",")' "$F")
assert_eq "$LABEL: rejection_mode offers binary + instances" "binary,instances" "$RM_VALUES"

# Every per-model rawSql gates on >= 100 responses and never scans req_body
ALL_SQL=$(jq -r '[.panels[].targets[].rawSql] | join("\n")' "$F")
GATED_PANELS=$(jq '[.panels[] | select((([.targets[].rawSql | test("count\\(\\) >= 100")]) | all) and ((.targets | length) > 0))] | length' "$F")
assert_eq "$LABEL: every panel query carries the >=100 relevance gate" "10" "$GATED_PANELS"
if printf '%s' "$ALL_SQL" | grep -q 'req_body'; then
    echo "[FAIL] $LABEL: rawSql references req_body (forbidden at refresh time)"; fail=$((fail+1))
else
    echo "[PASS] $LABEL: no rawSql references req_body"; pass=$((pass+1))
fi

# Mode toggle reaches the aggregating queries (p32 stat + p35 series)
P32_SQL=$(jq -r '[.panels[]|select(.id==32)][0].targets[0].rawSql' "$F")
P35_C_SQL=$(jq -r '[.panels[]|select(.id==35)][0].targets[] | select(.refId=="C") | .rawSql' "$F")
printf '%s' "$P32_SQL" | grep -q "rejection_mode" && { echo "[PASS] $LABEL: p32 honours rejection_mode"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p32 missing rejection_mode branch"; fail=$((fail+1)); }
printf '%s' "$P35_C_SQL" | grep -q "rejection_mode" && { echo "[PASS] $LABEL: p35 rejection series honours rejection_mode"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p35 missing rejection_mode branch"; fail=$((fail+1)); }
printf '%s' "$P32_SQL" | grep -q "sum(signal_weight)" && { echo "[PASS] $LABEL: instances mode sums valence-factored weights"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: instances mode missing sum(signal_weight)"; fail=$((fail+1)); }
if printf '%s' "$P32_SQL" | grep -q 'least(signal_count'; then
    echo "[FAIL] $LABEL: instances mode is capped (caps forbidden)"; fail=$((fail+1))
else
    echo "[PASS] $LABEL: instances mode has no cap"; pass=$((pass+1))
fi

# Normalization discipline: per-bucket denominators + sparse-bucket suppression
P35_A_SQL=$(jq -r '[.panels[]|select(.id==35)][0].targets[] | select(.refId=="A") | .rawSql' "$F")
printf '%s' "$P35_A_SQL" | grep -q 'HAVING countIf(is_stream = 1) >= 5' && { echo "[PASS] $LABEL: p35 suppresses sparse buckets (<5)"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p35 missing sparse-bucket HAVING"; fail=$((fail+1)); }

# Signed net (unclamped): p33 target C must subtract baseline without max(0,...)
P33_C_SQL=$(jq -r '[.panels[]|select(.id==33)][0].targets[] | select(.refId=="C") | .rawSql' "$F")
printf '%s' "$P33_C_SQL" | grep -q 'reactive - baseline' && { echo "[PASS] $LABEL: p33 net series is reactive - baseline"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p33 missing net series"; fail=$((fail+1)); }
if printf '%s' "$P33_C_SQL" | grep -q 'max(0'; then
    echo "[FAIL] $LABEL: p33 net is clamped (must be signed)"; fail=$((fail+1))
else
    echo "[PASS] $LABEL: p33 net is signed, unclamped"; pass=$((pass+1))
fi

# Baseline denominators exclude unparseable rows
P33_B_SQL=$(jq -r '[.panels[]|select(.id==33)][0].targets[] | select(.refId=="B") | .rawSql' "$F")
printf '%s' "$P33_B_SQL" | grep -q 'countIf(is_followup = 0 AND parsed = 1)' && { echo "[PASS] $LABEL: p33 baseline denominator gated on parsed=1"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p33 baseline denominator missing parsed gate"; fail=$((fail+1)); }

# Top rejection strings (FR-10.3): one merged table, censored, readable headers
P34_SQL=$(jq -r '[.panels[]|select(.id==34)][0].targets[0].rawSql' "$F")
printf '%s' "$P34_SQL" | grep -q 'arrayJoin(profane_terms)' && { echo "[PASS] $LABEL: p34 ranks profane_terms via arrayJoin"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p34 missing arrayJoin(profane_terms)"; fail=$((fail+1)); }
printf '%s' "$P34_SQL" | grep -qF 'substring(term, 1, 1)' && printf '%s' "$P34_SQL" | grep -qF "'***'" && { echo "[PASS] $LABEL: p34 censors profanity (first/last char + ***)"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p34 missing censoring"; fail=$((fail+1)); }
printf '%s' "$P34_SQL" | grep -qF 'UNION ALL' && printf '%s' "$P34_SQL" | grep -qF "'Frustration phrase'" && { echo "[PASS] $LABEL: p34 merges profanity + frustration with Category column"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p34 missing merged UNION ALL table"; fail=$((fail+1)); }
assert_eq "$LABEL: p34 is a single target (no A/B tabs)" "1" "$(jq '[.panels[]|select(.id==34)][0].targets|length' "$F")"
assert_eq "$LABEL: p34 title is censored rejection strings" "Top User Rejection Strings (censored)" "$(jq -r '[.panels[]|select(.id==34)][0].title' "$F")"

# Readable display names (FR-10.5): p32 title states metric and unit
assert_eq "$LABEL: p32 title states metric and unit" "User Rejection Rate (% of follow-up messages)" "$(jq -r '[.panels[]|select(.id==32)][0].title' "$F")"
P41_READABLE=$(jq -r '[.panels[]|select(.id==41)][0].targets[0].rawSql' "$F")
printf '%s' "$P41_READABLE" | grep -qF '"Net Rejection %"' && printf '%s' "$P41_READABLE" | grep -qF '"Switches %"' && { echo "[PASS] $LABEL: p41 columns use human-readable aliases"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p41 columns keep raw identifiers"; fail=$((fail+1)); }

# Overall Score (FR-9, revised 2026-09-16): score family with fixed goalposts,
# geometric aggregation, construct separation, >=30-request gate
P40_SQL=$(jq -r '[.panels[]|select(.id==40)][0].targets[0].rawSql' "$F")
printf '%s' "$P40_SQL" | grep -qF 'net_rej / 30' && printf '%s' "$P40_SQL" | grep -qF 'switch_rate / 100' && printf '%s' "$P40_SQL" | grep -qF 'cancel_rate / 5' && printf '%s' "$P40_SQL" | grep -qF 'abort_rate / 5' && { echo "[PASS] $LABEL: p40 uses fixed goalposts (30/100/5/5), not observed extrema"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p40 missing fixed goalposts"; fail=$((fail+1)); }
printf '%s' "$P40_SQL" | grep -qF 'power(' && printf '%s' "$P40_SQL" | grep -qF 'sqrt(' && { echo "[PASS] $LABEL: p40 aggregates geometrically (no factor can buy back another)"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p40 missing geometric aggregation"; fail=$((fail+1)); }
printf '%s' "$P40_SQL" | grep -q 'reqs >= 30' && { echo "[PASS] $LABEL: p40 requires >=30 requests (no tiny-sample ties)"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p40 missing >=30 gate"; fail=$((fail+1)); }
printf '%s' "$P40_SQL" | grep -qF 'ifNull' && { echo "[PASS] $LABEL: p40 missing factors count neutral 0.5"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p40 missing ifNull neutral"; fail=$((fail+1)); }
printf '%s' "$P40_SQL" | grep -qF 'guard_blocks' && { echo "[FAIL] $LABEL: p40 must not merge friction into the score (separate construct)"; fail=$((fail+1)); } || { echo "[PASS] $LABEL: p40 excludes friction (reported separately)"; pass=$((pass+1)); }
printf '%s' "$P40_SQL" | grep -qF 'ttft_content_ms' && { echo "[FAIL] $LABEL: p40 must not merge speed into the score"; fail=$((fail+1)); } || { echo "[PASS] $LABEL: p40 excludes speed factors"; pass=$((pass+1)); }
printf '%s' "$P40_SQL" | grep -qF 'argMax(model, timestamp)' && { echo "[PASS] $LABEL: p40 switch factor uses window-free session abandonment (CH window-in-join trap)"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p40 switch factor shape"; fail=$((fail+1)); }
P40_STEPS=$(jq -c '[.panels[]|select(.id==40)][0].fieldConfig.defaults.thresholds.steps' "$F")
printf '%s' "$P40_STEPS" | grep -q '"value":40' && printf '%s' "$P40_STEPS" | grep -q '"value":70' && { echo "[PASS] $LABEL: p40 verdict bands at 40/70"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p40 missing 40/70 thresholds"; fail=$((fail+1)); }
P40_DESC=$(jq -r '[.panels[]|select(.id==40)][0].description' "$F")
printf '%s' "$P40_DESC" | grep -qi 'heuristic' && { echo "[PASS] $LABEL: p40 carries behavioral-heuristic annotation"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p40 missing heuristic annotation"; fail=$((fail+1)); }

# Scorecard (FR-9.5): per-construct decomposition with readable headers
P41_SQL=$(jq -r '[.panels[]|select(.id==41)][0].targets[0].rawSql' "$F")
printf '%s' "$P41_SQL" | grep -qF '"Prompt Adherence (0-100)"' && printf '%s' "$P41_SQL" | grep -qF '"n Rejection"' && printf '%s' "$P41_SQL" | grep -qF '"Net Rejection %"' && printf '%s' "$P41_SQL" | grep -qF '"Overall Score"' && { echo "[PASS] $LABEL: p41 scorecard decomposes PAI + Overall with readable headers"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p41 scorecard columns missing"; fail=$((fail+1)); }
printf '%s' "$P41_SQL" | grep -qF '"Friction per 100 (context)"' && { echo "[PASS] $LABEL: p41 shows friction as context, not merged"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p41 missing friction context column"; fail=$((fail+1)); }

# Friction panels (FR-8.5): three marker classes, sparse suppression, stacking
P42_SQL=$(jq -r '[.panels[]|select(.id==42)][0].targets[].rawSql' "$F")
printf '%s' "$P42_SQL" | grep -q 'sum(guard_blocks)' && printf '%s' "$P42_SQL" | grep -q 'sum(user_rejections)' && printf '%s' "$P42_SQL" | grep -q 'sum(rule_denials)' && { echo "[PASS] $LABEL: p42 charts all three friction classes"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p42 missing a friction class"; fail=$((fail+1)); }
printf '%s' "$P42_SQL" | grep -q 'HAVING count() >= 5' && { echo "[PASS] $LABEL: p42 suppresses sparse buckets (<5)"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p42 missing sparse-bucket HAVING"; fail=$((fail+1)); }
P42_STACK=$(jq -r '[.panels[]|select(.id==42)][0].fieldConfig.defaults.custom.stacking' "$F")
assert_eq "$LABEL: p42 stacks the three classes" "normal" "$P42_STACK"
P42_DESC=$(jq -r '[.panels[]|select(.id==42)][0].description' "$F")
printf '%s' "$P42_DESC" | grep -qi 'lower bound' && { echo "[PASS] $LABEL: p42 documents the lower-bound caveat"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p42 missing lower-bound caveat"; fail=$((fail+1)); }

# Top guard rules (FR-8.5): arrayJoin over stored rule ids
P43_SQL=$(jq -r '[.panels[]|select(.id==43)][0].targets[0].rawSql' "$F")
printf '%s' "$P43_SQL" | grep -q 'arrayJoin(guard_rules)' && { echo "[PASS] $LABEL: p43 ranks guard_rules via arrayJoin"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p43 missing arrayJoin(guard_rules)"; fail=$((fail+1)); }

# Grouping (FR-10.6): verdict -> headline stats -> over time -> detail/friction
assert_eq "$LABEL: panels grouped top-to-bottom" "40 41 32 33 37 35 34 42 43 38" "$(jq -r '[.panels[].id] | map(tostring) | join(" ")' "$F")"

# Row-keyed bargauges show one gauge per row; bars compare from zero
assert_eq "$LABEL: bargauge panels use all-values reduce" "2/2" "$(jq -r '[.panels[]|select(.type=="bargauge")]|"\([.[]|select(.options.reduceOptions.values==true)]|length)/\(length)"' "$F")"
assert_eq "$LABEL: bargauge bars are zero-based" "2/2" "$(jq -r '[.panels[]|select(.type=="bargauge")]|"\([.[]|select(.fieldConfig.defaults.min==0)]|length)/\(length)"' "$F")"

# Cross-dashboard invariant: shared api_key + model templating identical
check_templating_sync

summary "test_dashboard_experience.sh"
