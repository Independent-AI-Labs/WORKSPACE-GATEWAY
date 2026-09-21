#!/bin/bash
set -euo pipefail

# Structure tests for Dashboard: Gateway Model Experience
# (conf/grafana/dashboards/gateway-model-experience.json)
# Panels: score leaderboard + scorecard + score cards, rejection rate/
# baseline/net, top rejection strings, session depth, friction rate,
# top guard rules.
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

# Panel inventory: 7 CH panels (p35/p33/p38 removed 2026-09-17:
# heavy per-bucket query, dubious reader value; p47 score cards added
# 2026-09-19: score cards with hover detail)
assert_eq "$LABEL: panel count is 6" "6" "$(jq '.panels|length' "$F")"
assert_eq "$LABEL: panel ids" "34 37 40 42 43 47" "$(jq -r '[.panels[].id] | sort | map(tostring) | join(" ")' "$F")"
assert_eq "$LABEL: ClickHouse panels" "6" "$(jq '[.panels[]|select(.datasource.uid=="clickhouse")]|length' "$F")"
assert_eq "$LABEL: Prometheus panels" "0" "$(jq '[.panels[]|select(.datasource.uid=="prometheus")]|length' "$F")"

# Generic structural checks (title/type/datasource/gridPos/target, refId,
# rawSql, brand palette, 90d/5s, no meta keys, formats, single-target tiles)
check_dashboard_basics "$F" "$LABEL"

# Template variables: model + api_key shared, plus dashboard-local
# include_local (rejection_mode and its p32 consumer removed 2026-09-17:
# the metric was vader/frustration/profanity lexicon coverage mislabeled
# as user rejections; explicit rejections remain in the p47 cards + p42)

# Local-model toggle (2026-09-17): include_local custom variable, default
# exclude, backed by llm_gateway.model_registry (synced from provider yamls)
IL_TYPE=$(jq -r '[.templating.list[]|select(.name=="include_local")]|if length==0 then "missing" else (.[0].type) end' "$F")
assert_eq "$LABEL: include_local variable exists" "custom" "$IL_TYPE"
IL_CURRENT=$(jq -r '.templating.list[]|select(.name=="include_local")|.current.value' "$F")
assert_eq "$LABEL: include_local default is exclude" "no" "$IL_CURRENT"
IL_VALUES=$(jq -r '[.templating.list[]|select(.name=="include_local")|.options[].value] | sort | join(",")' "$F")
assert_eq "$LABEL: include_local offers yes/no" "no,yes" "$IL_VALUES"
IL_ALL=$(jq -r '.templating.list[]|select(.name=="include_local")|.allValue // "missing"' "$F")
assert_eq "$LABEL: include_local has allValue (S6f quoted context)" "yes" "$IL_ALL"

# Every per-model rawSql gates on >= 100 responses and never scans req_body
ALL_SQL=$(jq -r '[.panels[].targets[].rawSql] | join("\n")' "$F")
GATED_PANELS=$(jq '[.panels[] | select((([.targets[].rawSql | test("count\\(\\) >= 100")]) | all) and ((.targets | length) > 0))] | length' "$F")
assert_eq "$LABEL: every panel query carries the >=100 relevance gate" "6" "$GATED_PANELS"
if printf '%s' "$ALL_SQL" | grep -q 'req_body'; then
    echo "[FAIL] $LABEL: rawSql references req_body (forbidden at refresh time)"; fail=$((fail+1))
else
    echo "[PASS] $LABEL: no rawSql references req_body"; pass=$((pass+1))
fi

# rejection_mode removed with p32: no variable, no consumer panel
RM_GONE=$(jq '[.templating.list[]|select(.name=="rejection_mode")]|length' "$F")
assert_eq "$LABEL: rejection_mode variable removed" "0" "$RM_GONE"
P32_GONE=$(jq '[.panels[]|select(.id==32)]|length' "$F")
assert_eq "$LABEL: p32 panel removed" "0" "$P32_GONE"

# Top rejection strings (FR-10.3): one merged table, censored, readable headers
P34_SQL=$(jq -r '[.panels[]|select(.id==34)][0].targets[0].rawSql' "$F")
printf '%s' "$P34_SQL" | grep -q 'arrayJoin(profane_terms)' && { echo "[PASS] $LABEL: p34 ranks profane_terms via arrayJoin"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p34 missing arrayJoin(profane_terms)"; fail=$((fail+1)); }
printf '%s' "$P34_SQL" | grep -qF 'substring(term, 1, 1)' && printf '%s' "$P34_SQL" | grep -qF "'***'" && { echo "[PASS] $LABEL: p34 censors profanity (first/last char + ***)"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p34 missing censoring"; fail=$((fail+1)); }
printf '%s' "$P34_SQL" | grep -qF 'UNION ALL' && printf '%s' "$P34_SQL" | grep -qF "'Frustration phrase'" && { echo "[PASS] $LABEL: p34 merges profanity + frustration with Category column"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p34 missing merged UNION ALL table"; fail=$((fail+1)); }
assert_eq "$LABEL: p34 is a single target (no A/B tabs)" "1" "$(jq '[.panels[]|select(.id==34)][0].targets|length' "$F")"
assert_eq "$LABEL: p34 title is censored rejection strings" "Top User Rejection Strings (censored)" "$(jq -r '[.panels[]|select(.id==34)][0].title' "$F")"

# Readable display names (FR-10.5): carried by the p47 card aliases below
# (p41 scorecard table removed 2026-09-19 -- superseded by the score cards)

# Overall Score (FR-9, revised 2026-09-16): score family with fixed goalposts,
# geometric aggregation, construct separation, >=30-request gate
P40_SQL=$(jq -r '[.panels[]|select(.id==40)][0].targets[0].rawSql' "$F")
printf '%s' "$P40_SQL" | grep -qF 'net_rej / 50' && printf '%s' "$P40_SQL" | grep -qF 'switch_rate / 100' && printf '%s' "$P40_SQL" | grep -qF 'cancel_rate / 5' && printf '%s' "$P40_SQL" | grep -qF 'abort_rate / 5' && { echo "[PASS] $LABEL: p40 uses fixed goalposts (50/100/5/5), not observed extrema"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p40 missing fixed goalposts"; fail=$((fail+1)); }
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

# Score cards (p47, 2026-09-19): Business Text panel (grafana/business-text,
# Apache-2.0, community-signed, preinstalled via GF_PLUGINS_PREINSTALL --
# test_compose.sh asserts presence; bare IDs only, the env var has no
# version-pin syntax). Flat HTML cards from the score-family
# query; CSS-only hover popover carries the full decomposition. Template HTML
# passes Grafana's DOMPurify sanitizer; disable_sanitize_html stays false.
P47_TYPE=$(jq -r '[.panels[]|select(.id==47)][0].type // "missing"' "$F")
assert_eq "$LABEL: p47 is a Business Text panel" "marcusolsson-dynamictext-panel" "$P47_TYPE"
P47_CONTENT=$(jq -r '[.panels[]|select(.id==47)][0].options.content' "$F")
P47_STYLES=$(jq -r '[.panels[]|select(.id==47)][0].options.styles' "$F")
assert_eq "$LABEL: p47 renders once over all rows (single query, no edge frame)" "allRows" "$(jq -r '[.panels[]|select(.id==47)][0].options.renderMode' "$F")"
assert_eq "$LABEL: p47 single target (no duplicated score-family query)" "1" "$(jq '[.panels[]|select(.id==47)][0].targets|length' "$F")"
printf '%s' "$P47_CONTENT" | grep -qF '{{#each data}}' && printf '%s' "$P47_CONTENT" | grep -qF '{{score}}' && printf '%s' "$P47_CONTENT" | grep -qF '{{model}}' && printf '%s' "$P47_CONTENT" | grep -qF "gw-{{verdict}}" && { echo "[PASS] $LABEL: p47 cards iterate models with verdict-colored markup"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p47 card markup missing"; fail=$((fail+1)); }
printf '%s' "$P47_CONTENT" | grep -qF '{{rej}}' && printf '%s' "$P47_CONTENT" | grep -qF '{{sw}}' && printf '%s' "$P47_CONTENT" | grep -qF '{{canc}}' && printf '%s' "$P47_CONTENT" | grep -qF '{{ab}}' && printf '%s' "$P47_CONTENT" | grep -qF '{{fric}}' && { echo "[PASS] $LABEL: p47 hover popover carries the full decomposition"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p47 popover fields missing"; fail=$((fail+1)); }
printf '%s' "$P47_STYLES" | grep -qF '.gw-card:hover .gw-pop' && printf '%s' "$P47_STYLES" | grep -qF '.gw-pop { display: none' && { echo "[PASS] $LABEL: p47 popover is CSS-only (hidden until hover)"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p47 hover CSS missing"; fail=$((fail+1)); }
P47_SQL=$(jq -r '[.panels[]|select(.id==47)][0].targets[0].rawSql' "$F")
printf '%s' "$P47_SQL" | grep -qF 'model_registry' && printf '%s' "$P47_SQL" | grep -qF "'\${include_local}'" && printf '%s' "$P47_SQL" | grep -q 'reqs >= 30' && { echo "[PASS] $LABEL: p47 honours include_local + >=30 gate"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p47 missing gates"; fail=$((fail+1)); }

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

# Grouping (FR-10.6): verdict headline -> session depth -> cards -> detail/friction
assert_eq "$LABEL: panels grouped top-to-bottom" "40 37 47 34 42 43" "$(jq -r '[.panels[].id] | map(tostring) | join(" ")' "$F")"

# Local-model toggle reaches both score panels (p40 + p47)
printf '%s' "$P40_SQL" | grep -qF 'model_registry' && printf '%s' "$P40_SQL" | grep -qF "'\${include_local}'" && { echo "[PASS] $LABEL: p40 honours include_local via model_registry"; pass=$((pass+1)); } || { echo "[FAIL] $LABEL: p40 missing include_local predicate"; fail=$((fail+1)); }

# Row-keyed bargauges show one gauge per row; bars compare from zero
assert_eq "$LABEL: bargauge panels use all-values reduce" "2/2" "$(jq -r '[.panels[]|select(.type=="bargauge")]|"\([.[]|select(.options.reduceOptions.values==true)]|length)/\(length)"' "$F")"
assert_eq "$LABEL: bargauge bars are zero-based" "2/2" "$(jq -r '[.panels[]|select(.type=="bargauge")]|"\([.[]|select(.fieldConfig.defaults.min==0)]|length)/\(length)"' "$F")"

# Cross-dashboard invariant: shared api_key + model templating identical
check_templating_sync

summary "test_dashboard_experience.sh"
