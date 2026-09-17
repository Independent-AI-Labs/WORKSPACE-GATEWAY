#!/bin/bash
# dashboard_assert.sh - shared helpers for per-dashboard structure tests.
# Sourced by test_dashboard_cost_usage.sh, test_dashboard_ops_health.sh,
# and test_dashboard_cost_leaderboard.sh. Not invoked directly.

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
    _SELF="$SHG_SCRIPT_PATH"
fi
REPO_ROOT="$(cd "$(dirname "$_SELF")/../.." && pwd)"
DASH_DIR="$REPO_ROOT/conf/grafana/dashboards"
COST_USAGE_FILE="$DASH_DIR/gateway-cost-usage.json"
OPS_HEALTH_FILE="$DASH_DIR/gateway-ops-health.json"
LEADERBOARD_FILE="$DASH_DIR/gateway-cost-leaderboard.json"
EXPERIENCE_FILE="$DASH_DIR/gateway-model-experience.json"
PERFORMANCE_FILE="$DASH_DIR/gateway-model-performance.json"
ALL_DASHBOARDS=("$COST_USAGE_FILE" "$OPS_HEALTH_FILE" "$LEADERBOARD_FILE" "$EXPERIENCE_FILE" "$PERFORMANCE_FILE")

pass=0
fail=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "[PASS] $desc"
        pass=$((pass + 1))
    else
        echo "[FAIL] $desc: expected: $expected, actual: $actual"
        fail=$((fail + 1))
    fi
}

assert_gt() {
    local desc="$1" threshold="$2" actual="$3"
    if [ "$actual" -gt "$threshold" ]; then
        echo "[PASS] $desc"
        pass=$((pass + 1))
    else
        echo "[FAIL] $desc: expected > $threshold, got $actual"
        fail=$((fail + 1))
    fi
}

assert_json_valid() {
    local desc="$1" file="$2"
    if jq empty "$file"; then
        echo "[PASS] $desc"
        pass=$((pass + 1))
    else
        echo "[FAIL] $desc: not valid JSON ($file)"
        fail=$((fail + 1))
    fi
}

# Generic structural checks run against any single dashboard file.
# Args: $1 = dashboard file path
check_dashboard_basics() {
    local f="$1"
    local label="$2"

    [ -f "$f" ] || { echo "[FAIL] $label missing: $f"; fail=$((fail+1)); return 1; }

    # S6: every panel has title, type, datasource.uid, gridPos, >=1 target
    local missing
    missing=$(jq -r '
      [.panels[]
        | select(
            (.title // null) == null or
            (.type // null) == null or
            (.datasource.uid // null) == null or
            (.gridPos // null) == null or
            ((.targets // []) | length) == 0
          )
      ] | length
    ' "$f")
    assert_eq "$label S6: all panels have title/type/datasource/gridPos/target" "0" "$missing"

    # S6b: every target has refId
    local no_refid
    no_refid=$(jq -r '[.panels[].targets[] | select((.refId // null) == null)] | length' "$f")
    assert_eq "$label S6b: all targets have refId" "0" "$no_refid"

    # S6c: CH targets have rawSql; Prom targets have expr
    local ch_no_sql prom_no_expr
    ch_no_sql=$(jq -r '[.panels[]|select(.datasource.uid=="clickhouse")|.targets[]|select((.rawSql//null)==null)]|length' "$f")
    assert_eq "$label S6c: all ClickHouse targets have rawSql" "0" "$ch_no_sql"
    prom_no_expr=$(jq -r '[.panels[]|select(.datasource.uid=="prometheus")|.targets[]|select((.expr//null)==null)]|length' "$f")
    assert_eq "$label S6c: all Prometheus targets have expr" "0" "$prom_no_expr"

    # S6d: override matcher ids must exist in Grafana's registry (case-sensitive)
    local bad_matchers
    bad_matchers=$(jq -r '
      def valid: ["anyMatch","allMatch","invertMatch","alwaysMatch","neverMatch","byType","byTypes","numeric","time","byName","byNames","byRegexp","byRegexpOrNames","byFrameRefID","first","firstTimeField","byValue"];
      [.panels[] | .id as $pid | .fieldConfig.overrides[]? | .matcher.id | select(. != null) | select(. as $id | valid | index($id) | not)] | unique | join(",")
    ' "$f")
    assert_eq "$label S6d: override matcher ids are valid Grafana matcher ids" "" "$bad_matchers"

    # S6e: stat/bargauge panels must be single-target (multi-target stat frames
    # prefix field names with refIds and drop string fields)
    local multi_target_tiles
    multi_target_tiles=$(jq -r '[.panels[] | select(.type=="stat" or .type=="bargauge") | select((.targets|length) > 1) | .id] | join(",")' "$f")
    assert_eq "$label S6e: stat/bargauge panels are single-target" "" "$multi_target_tiles"

    # S6f: variables used in single-quoted SQL context ('${var}') must define a
    # custom allValue. Kiosk/embed URLs force var-<name>=$__all; without an
    # allValue Grafana expands All to a multi-value list that breaks the
    # single-value comparison (ClickHouse syntax error, HTTP 400).
    local no_allval
    no_allval=$(jq -r '
      [.] | .[0] as $root
      | [ $root.templating.list[] | .name as $n
        | ([ $root.panels[].targets[]?.rawSql // ""
            | select((contains("\u0027${" + $n + "}")) or (contains("\u0027${" + $n + ":"))) ] | length) as $quoted
        | select($quoted > 0)
        | select((.allValue // "") == "")
        | $n
      ] | join(",")
    ' "$f")
    assert_eq "$label S6f: single-quoted variables have custom allValue" "" "$no_allval"

    # S7: all hex colors are brand palette
    local brand_hex
    brand_hex=$(jq -r '
      def brand: ["#50514f","#f25f5c","#ffe066","#247ba0","#70c1b3","#a5d0a8","#8cada7","#110b11","#b7990d","#f2f4cb","#ffffff","#c9a44c","#a8a9ad","#b07a3c"];
      def is_brand(c): c as $c | brand | index($c | ascii_downcase) != null;
      def is_hex(c): (c | startswith("#"));
      [ .panels[] | . as $p |
        ( .fieldConfig.defaults.color? | select(.mode == "fixed") | .fixedColor? | select(. != null) | . as $c |
          if (is_hex($c) and (is_brand($c) | not)) then "p\($p.id) default \($c | ascii_downcase)" else empty end
        ),
        ( .fieldConfig.defaults.thresholds.steps[]? | .color? | select(. != null) | . as $c |
          if (is_hex($c) and (is_brand($c) | not)) then "p\($p.id) threshold \($c | ascii_downcase)" else empty end
        ),
        ( .fieldConfig.overrides[]? | . as $o | .properties[]? | select(.id == "color") | .value? | select(.mode == "fixed") | .fixedColor? | select(. != null) | . as $c |
          if (is_hex($c) and (is_brand($c) | not)) then "p\($p.id) override[\($o.matcher.options)] \($c | ascii_downcase)" else empty end
        )
      ] as $violations |
      if ($violations | length) == 0 then "OK" else "VIOLATIONS: " + ($violations | join(" | ")) end
    ' "$f")
    assert_eq "$label S7: all hex colors are brand palette" "OK" "$brand_hex"

    # S8: time range and refresh
    assert_eq "$label S8: time.from is now-90d" "now-90d" "$(jq -r '.time.from' "$f")"
    assert_eq "$label S8: time.to is now" "now" "$(jq -r '.time.to' "$f")"
    assert_eq "$label S8: refresh is 5s" "5s" "$(jq -r '.refresh' "$f")"
    assert_eq "$label S8: timepicker lists 5s refresh" "5s" "$(jq -r '.timepicker.refresh_intervals[0]' "$f")"
    assert_eq "$label S8: timepicker lists 7d range" "7d" "$(jq -r '.timepicker.time_options[-2]' "$f")"

    # S9: no $__conditionalAll; api_key no allValue; model UNIONs both tables
    local cond_all api_key_all model_query
    cond_all=$(jq -r '[.panels[].targets[]|(.rawSql//.expr//"")|select(.!=null)|select(test("\\$\\$__conditionalAll"))]|length' "$f")
    assert_eq "$label S9: no \$__conditionalAll macros" "0" "$cond_all"
    api_key_all=$(jq -r '[.templating.list[]|select(.name=="api_key")]|if length==0 then "error" else (.[0].allValue|if .==null or .=="" then "None" else . end) end' "$f")
    assert_eq "$label S9: api_key variable has no allValue" "None" "$api_key_all"
    model_query=$(jq -r '[.templating.list[]|select(.name=="model")]|if length==0 then "error" else (.[0].query|ascii_upcase|if test("UNION") then "union" else "single" end) end' "$f")
    assert_eq "$label S9: model variable UNIONs both tables" "union" "$model_query"

    # S13: no meta/editorType/pluginVersion on CH targets
    local ch_meta
    ch_meta=$(jq -r '[.panels[]|select(.datasource.uid=="clickhouse")|.targets[]|select(has("meta") or has("editorType") or has("pluginVersion"))]|length' "$f")
    assert_eq "$label S13: no ClickHouse target has meta/editorType/pluginVersion" "0" "$ch_meta"

    # S1: CH targets use format table or timeseries (not numeric/earlier)
    local ch_bad_fmt
    ch_bad_fmt=$(jq -r '[.panels[]|select(.datasource.uid=="clickhouse")|.targets[]|select(.format!=null)|select(.format!="table" and .format!="timeseries")]|length' "$f")
    assert_eq "$label S1: no ClickHouse panel uses numeric/earlier format" "0" "$ch_bad_fmt"

    # S2: CH timeseries panels use format timeseries
    local ch_ts_bad
    ch_ts_bad=$(jq -r '[.panels[]|select(.datasource.uid=="clickhouse" and .type=="timeseries")|.targets[]|select(.format!="timeseries")]|length' "$f")
    assert_eq "$label S2: ClickHouse timeseries panels use format timeseries" "0" "$ch_ts_bad"

    # S16: CH bargauge/stat panels use format table
    local ch_table_bad
    ch_table_bad=$(jq -r '[.panels[]|select(.datasource.uid=="clickhouse" and (.type=="bargauge" or .type=="stat"))|.targets[]|select(.format!="table")]|length' "$f")
    assert_eq "$label S16: ClickHouse bargauge/stat panels use format table" "0" "$ch_table_bad"

    # S18: value formatting conventions on tile SQL (all dashboards):
    #  (a) currency must use the rollover-safe integer-cents pattern
    #      (round(x*100), floor(c/100), c%100); the fractional form
    #      round((x - floor(x)) * 100) yields 100 cents on x like 1893.995
    #      and renders "$1893.100".
    #  (b) compact B/M/K must round, never floor-truncate: floor((v % d)/...)
    #      drops up to a display unit (106059 -> 106.05K).
    local money_sql bad_cents_rc bad_cents bad_trunc
    money_sql=$(jq -r --arg n "concat('\$'" '[.panels[].targets[].rawSql // empty | select(contains($n))] | join("\n")' "$f")
    bad_cents=$(printf '%s\n' "$money_sql" | grep -c ' - floor(' ) || bad_cents_rc=$?
    bad_cents=${bad_cents:-0}
    assert_eq "$label S18: currency uses rollover-safe integer cents (no x - floor(x) fraction)" "0" "$bad_cents"
    bad_trunc=$(jq -r '[.panels[].targets[].rawSql // empty | select(test("floor\\(\\(?[a-zA-Z_]+ % |floor\\([a-zA-Z_ ]+\\) / 1[0-9]+\\)"))] | length' "$f")
    assert_eq "$label S18: compact B/M/K rounds (no floor-truncated decimals)" "0" "$bad_trunc"
}

# Cross-dashboard invariant: the shared variables (api_key + model) are
# byte-identical across all 4 dashboards (same filter header). Dashboard-local
# variables (e.g. gateway-usefulness rejection_mode) are excluded. Run from
# any one of the dashboard test files.
check_templating_sync() {
    local ok=1 t_ref t_f
    t_ref=$(jq -c '[.templating.list[] | select(.name == "api_key" or .name == "model")]' "$COST_USAGE_FILE")
    for f in "${ALL_DASHBOARDS[@]}"; do
        t_f=$(jq -c '[.templating.list[] | select(.name == "api_key" or .name == "model")]' "$f")
        if [ "$t_f" != "$t_ref" ]; then
            echo "[FAIL] Templating differs: $f"
            echo "       reference : $t_ref"
            echo "       actual    : $t_f"
            ok=0
        fi
    done
    if [ "$ok" -eq 1 ]; then
        echo "[PASS] Templating (api_key + model) identical across all ${#ALL_DASHBOARDS[@]} dashboards"
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
    fi
}

summary() {
    local name="$1"
    echo ""
    echo "$name: $pass passed, $fail failed"
    if [ "$fail" -gt 0 ]; then
        exit 1
    fi
    exit 0
}
