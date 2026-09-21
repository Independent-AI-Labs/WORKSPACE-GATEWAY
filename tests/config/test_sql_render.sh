#!/bin/bash
# test_sql_render.sh: conf/sql renderer + lint-context contract.
#   * sql_render resolves {{NAME}} from VARS / override / SQL_<NAME> env
#   * grafana mode emits $__ / ${} macros; raw mode emits valid SQL
#   * an unresolved template variable fails closed
#   * .sqlfluff jinja context and VARS hold the same keys
#   * .sqlfluff jinja macros and lib-sql.sh know the same macro names
set -euo pipefail

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
    _SELF="$SHG_SCRIPT_PATH"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

export REPO_ROOT
# shellcheck source=/dev/null
source "$REPO_ROOT/res/scripts/lib-sql.sh" || exit 1

pass=0
fail=0
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "[PASS] $desc"
        pass=$((pass + 1))
    else
        echo "[FAIL] $desc -- expected: [$expected], actual: [$actual]"
        fail=$((fail + 1))
    fi
}

raw="$(sql_render tests/render_sample.sql)"
assert_eq "raw: VARS fills {{DB}}" "1" "$(printf '%s' "$raw" | grep -c 'FROM llm_gateway.usage_log')"
assert_eq "raw: time_filter becomes a predicate" "1" \
    "$(printf '%s' "$raw" | grep -c 'timestamp >= now() - INTERVAL 1 DAY')"
assert_eq "raw: gf_str becomes quoted sample" "1" \
    "$(printf '%s' "$raw" | grep -c "environment = 'sample'")"

override="$(sql_render tests/render_sample.sql DB=other_db)"
assert_eq "override beats VARS" "1" "$(printf '%s' "$override" | grep -c 'FROM other_db.usage_log')"

envval="$(SQL_DB=env_db sql_render tests/render_sample.sql)"
assert_eq "SQL_<NAME> env fills {{DB}}" "1" "$(printf '%s' "$envval" | grep -c 'FROM env_db.usage_log')"

grafana="$(SQL_RENDER_MODE=grafana sql_render tests/render_sample.sql)"
assert_eq "grafana: time_filter -> \$__timeFilter" "1" \
    "$(printf '%s' "$grafana" | grep -cF '$__timeFilter(timestamp)')"
assert_eq "grafana: gf_str/gf_str_multi -> \${...:singlequote}" "3" \
    "$(printf '%s' "$grafana" | grep -cF ':singlequote}')"
assert_eq "grafana: gf_num -> \${...}" "1" \
    "$(printf '%s' "$grafana" | grep -cF 'topn = ${topn}')"

unresolved_tmpl="$(mktemp)"
trap 'rm -f "$unresolved_tmpl"' EXIT
printf 'SELECT {{NOTE_A_REAL_PLACEHOLDER}};\n' > "$unresolved_tmpl"
unresolved_rc=0
unresolved_out="$(sql_render "$unresolved_tmpl" 2>&1)" || unresolved_rc=$?
if [ "$unresolved_rc" -eq 0 ]; then
    printf '%s\n' "$unresolved_out"
    echo "[FAIL] unresolved {{NOTE_A_REAL_PLACEHOLDER}} unexpectedly rendered"
    fail=$((fail + 1))
else
    echo "[PASS] unresolved template variable fails closed"
    pass=$((pass + 1))
fi

echo "=== every conf/sql template renders (raw + grafana) ==="
# Unresolved template variables and malformed {{...}} must fail closed at render
# time; with only VARS defaults, every committed template must produce SQL.
render_fail=0
while IFS= read -r f; do
    rel="${f#conf/sql/}"
    if ! raw_out="$(sql_render "$rel" 2>&1)"; then
        echo "  raw render failed: $rel"
        printf '%s\n' "$raw_out"
        render_fail=$((render_fail + 1))
    fi
    if ! graf_out="$(SQL_RENDER_MODE=grafana sql_render "$rel" 2>&1)"; then
        echo "  grafana render failed: $rel"
        printf '%s\n' "$graf_out"
        render_fail=$((render_fail + 1))
    fi
done < <(find conf/sql -name '*.sql' | sort)
assert_eq "all templates render in both modes" "0" "$render_fail"

echo "=== lib-sql.sh failure modes and precedence ==="
missing_rc=0
missing_out="$(sql_render no/such/template.sql 2>&1)" || missing_rc=$?
bad_rc=0
bad_out="$(sql_render tests/render_sample.sql =oops 2>&1)" || bad_rc=$?
assert_eq "missing template fails closed" "1" "$missing_rc"
assert_eq "missing template reports the path" "1" \
    "$(printf '%s' "$missing_out" | grep -c 'no such template')"
assert_eq "empty-name override is rejected" "2" "$bad_rc"
assert_eq "empty-name override reports the bad arg" "1" \
    "$(printf '%s' "$bad_out" | grep -c 'bad override')"
# Precedence: NAME=VALUE argument beats SQL_<NAME> in the environment.
prec="$(SQL_DB=env_db sql_render tests/render_sample.sql DB=arg_db)"
assert_eq "arg override beats SQL_ env" "1" \
    "$(printf '%s' "$prec" | grep -c 'FROM arg_db.usage_log')"

echo "=== .sqlfluff context keys match conf/sql/VARS ==="
vars_keys="$(grep -vE '^[[:space:]]*(#|$)' conf/sql/VARS | cut -d= -f1 | sort)"
ctx_keys="$(awk '
    /^\[sqlfluff:templater:jinja:context\]/ {inctx=1; next}
    /^\[/ {inctx=0}
    inctx && /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/ {sub(/[[:space:]]*=.*/,""); print}
' .sqlfluff | sort)"
assert_eq "context keys == VARS keys" "$vars_keys" "$ctx_keys"

echo "=== .sqlfluff macro names match lib-sql.sh ==="
cfg_macros="$(awk '
    /^\[sqlfluff:templater:jinja:macros\]/ {inmac=1; next}
    /^\[/ {inmac=0}
    inmac && /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/ {sub(/[[:space:]]*=.*/,""); print}
' .sqlfluff | sort | tr '\n' ' ')"
assert_eq "macros declared in both places" "gf_num gf_str gf_str_multi time_filter " "$cfg_macros"
for m in time_filter gf_num gf_str gf_str_multi; do
    if grep -qF "/^${m}\(" "$REPO_ROOT/res/scripts/lib-sql.sh"; then
        handled=1
    else
        handled=0
    fi
    assert_eq "lib-sql.sh handles $m" "1" "$handled"
done

echo ""
echo "test_sql_render.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
