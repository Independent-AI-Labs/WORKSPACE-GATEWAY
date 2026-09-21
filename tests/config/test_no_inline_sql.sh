#!/bin/bash
# test_no_inline_sql.sh: every SQL statement lives in conf/sql/, never inline
# in shell, Lua, or Grafana dashboard JSON. Loader contract:
#   * shell:  source res/scripts/lib-sql.sh; sql_render <template> [K=V...]
#   * lua:    io.open(".../conf/sql/...")
#   * grafana: dashboard rawSql is "{{sql:<path>}}", expanded before reload.
set -euo pipefail

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
    _SELF="$SHG_SCRIPT_PATH"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

pass=0
fail=0

# Statement starters that only ever appear in real SQL. Deliberately
# anchored to whole keywords so prose/identifiers do not trip it.
SQL_PATTERN='(SELECT[[:space:]]+.*[[:space:]]FROM[[:space:]]|INSERT[[:space:]]+INTO[[:space:]]|CREATE[[:space:]]+(TABLE|MATERIALIZED[[:space:]]+VIEW|DATABASE)[[:space:]]|ALTER[[:space:]]+TABLE[[:space:]]|DROP[[:space:]]+TABLE[[:space:]]|BACKUP[[:space:]]+DATABASE[[:space:]]|OPTIMIZE[[:space:]]+TABLE[[:space:]]|TRUNCATE[[:space:]]+TABLE[[:space:]]|DELETE[[:space:]]+FROM[[:space:]])'

echo "=== Inline SQL outside conf/sql/ ==="
inline_hits=""
while IFS= read -r f; do
    case "$f" in
        conf/sql/*) continue ;;
        # Generated Grafana render (built from conf/sql by
        # res/scripts/render-grafana-dashboards.sh); drift-checked, not source.
        conf/grafana/rendered/*) continue ;;
        tests/config/test_no_inline_sql.sh) continue ;;
        # The renderer names SQL statement keywords only in comments/regex.
        res/scripts/lib-sql.sh) continue ;;
        # Container bootstrap: runs as ClickHouse initdb before any repo/conf
        # mount exists, and its user DDL embeds secrets. Kept inline and
        # fail-closed on purpose (see SPEC-SQL-STRUCTURE section 5).
        res/docker/clickhouse-provision.sh) continue ;;
    esac
    # Skip matches that are not executed SQL: awk/sed/grep pattern strings
    # (e.g. DDL extracted from a conf/sql file, or test assertions about
    # schema text). Actual query execution (ch/curl/clickhouse-client) still
    # trips the pattern.
    if hits="$(grep -nEI "$SQL_PATTERN" "$f" \
        | grep -vE '^[0-9]+:[[:space:]]*(#|--)' \
        | grep -vE '(grep|awk|sed) |assert_contains|assert_not_contains' \
        | grep -v 'conf/sql/')"; then
        :
    else
        hits=""
    fi
    if [ -n "$hits" ]; then
        inline_hits="${inline_hits}${f}:\n${hits}\n"
    fi
done < <(git ls-files '*.sh' '*.lua' '*.json' '*.yaml' '*.yml')

if [ -n "$inline_hits" ]; then
    printf '%b' "$inline_hits"
    echo "[FAIL] inline SQL found outside conf/sql/ (move it and sql_render)"
    fail=$((fail + 1))
else
    echo "[PASS] no inline SQL in shell/Lua/YAML"
    pass=$((pass + 1))
fi

echo "=== Grafana rawSql must be {{sql:<path>}} ==="
if grafana_hits="$(grep -rnEI '"rawSql"[[:space:]]*:[[:space:]]*"[^"]*(SELECT|INSERT INTO|FROM )' \
    conf/grafana/dashboards conf/grafana/provisioning | grep -v '{{sql:')"; then
    :
else
    grafana_hits=""
fi
if [ -n "$grafana_hits" ]; then
    printf '%s\n' "$grafana_hits"
    echo "[FAIL] literal SQL in Grafana rawSql (use {{sql:<path>}})"
    fail=$((fail + 1))
else
    echo "[PASS] Grafana rawSql is templated"
    pass=$((pass + 1))
fi

echo "=== Shell SQL loader is guard-safe ==="
# The shell guard stages an agent script in a sealed memfd and execs it as
# /proc/self/fd/N, injecting the real path as SHG_SCRIPT_PATH. A script that
# derives its directory from BASH_SOURCE and then sources lib-sql.sh resolves
# /proc/... and dies. Entry scripts must use SHG_SCRIPT_PATH; lib-*
# files are only sourced (real BASH_SOURCE) and are exempt.
loader_unsafe=""
while IFS= read -r f; do
    case "$f" in
        res/scripts/lib-sql.sh|*/lib-*.sh) continue ;;
    esac
    grep -qF 'lib-sql.sh' "$f" || continue
    if grep -qF 'BASH_SOURCE' "$f" && ! grep -qF 'SHG_SCRIPT_PATH' "$f"; then
        loader_unsafe="${loader_unsafe}${f}\n"
    fi
done < <(git ls-files '*.sh')
if [ -n "$loader_unsafe" ]; then
    printf '%b' "$loader_unsafe"
    echo "[FAIL] scripts sourcing lib-sql.sh must resolve their own path via SHG_SCRIPT_PATH"
    fail=$((fail + 1))
else
    echo "[PASS] shell SQL loaders resolve paths guard-safely"
    pass=$((pass + 1))
fi

echo ""
echo "test_no_inline_sql.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
