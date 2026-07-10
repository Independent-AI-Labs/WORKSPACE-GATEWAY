#!/bin/bash
set -euo pipefail

# tests/config/test_migrations.sh
# Persistent validation of the golang-migrate schema-migration framework
# (ClickHouse-KB-recommended). Asserts: directory layout, file naming,
# compose `migrate` service, ansible orchestration, Makefile routing,
# ARCHITECTURE.md references, and that the legacy hand-rolled framework
# has been fully removed. Does NOT require a running ClickHouse.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MIGRATIONS_DIR="$REPO_ROOT/conf/migrations"
COMPOSE_FILE="$REPO_ROOT/res/docker/docker-compose.yml"
ANSIBLE_FILE="$REPO_ROOT/res/ansible/dev.yml"
MAKEFILE="$REPO_ROOT/Makefile"
ARCH_FILE="$REPO_ROOT/docs/ARCHITECTURE.md"

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

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "[PASS] $desc"
        pass=$((pass + 1))
    else
        echo "[FAIL] $desc -- missing: [$needle]"
        fail=$((fail + 1))
    fi
}

assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "[PASS] $desc"
        pass=$((pass + 1))
    else
        echo "[FAIL] $desc -- unexpectedly contains: [$needle]"
        fail=$((fail + 1))
    fi
}

# ── (A) regression guards: old hand-rolled framework fully removed ──────
assert_eq "scripts/clickhouse-migrate.sh removed" "false" \
    "$([ -f "$REPO_ROOT/scripts/clickhouse-migrate.sh" ] && echo true || echo false)"
assert_eq "scripts/ch-migrate.sh removed" "false" \
    "$([ -f "$REPO_ROOT/scripts/ch-migrate.sh" ] && echo true || echo false)"
assert_eq "legacy conf/clickhouse-migration-cost-source.sql removed" "false" \
    "$([ -f "$REPO_ROOT/conf/clickhouse-migration-cost-source.sql" ] && echo true || echo false)"

# ── (B) migrations directory layout ─────────────────────────────────────
assert_eq "migrations directory exists" "true" \
    "$([ -d "$MIGRATIONS_DIR" ] && echo true || echo false)"

mapfile -t mig_files < <(find "$MIGRATIONS_DIR" -maxdepth 1 -type f -name '*.sql' 2>/dev/null | sort || true)
file_count="${#mig_files[@]}"
assert_eq "at least one migration file exists" "true" \
    "$([ "$file_count" -gt 0 ] && echo true || echo false)"

# every file must match NNNNNN_*.up.sql or NNNNNN_*.down.sql naming
bad_naming=0
bad_header=0
up_files=()
down_files=()
for f in "${mig_files[@]}"; do
    bn="$(basename "$f")"
    case "$bn" in
        [0-9][0-9][0-9][0-9][0-9][0-9]_*.up.sql)   up_files+=("$bn") ;;
        [0-9][0-9][0-9][0-9][0-9][0-9]_*.down.sql) down_files+=("$bn") ;;
        *) echo "[FAIL] migration not NNNNNN_*.{up,down}.sql named: $bn"; bad_naming=$((bad_naming + 1)) ;;
    esac
    first_line="$(head -1 "$f")"
    case "$first_line" in
        --*) ;;
        *) echo "[FAIL] migration does not start with SQL comment: $bn"; bad_header=$((bad_header + 1)) ;;
    esac
done
assert_eq "all migrations NNNNNN_*.{up,down}.sql named" "0" "$bad_naming"
assert_eq "all migrations start with -- comment" "0" "$bad_header"

# every .up.sql must have a matching .down.sql
missing_down=0
for uf in "${up_files[@]}"; do
    stem="${uf%.up.sql}"
    matching_down="${stem}.down.sql"
    if [ ! -f "$MIGRATIONS_DIR/$matching_down" ]; then
        echo "[FAIL] missing .down.sql for: $uf"
        missing_down=$((missing_down + 1))
    fi
done
assert_eq "every .up.sql has matching .down.sql" "0" "$missing_down"

# 000003 .down.sql is irreversible (comments-only, no executable SQL;
# golang-migrate convention: `down` succeeds but makes no schema change).
down_003="$MIGRATIONS_DIR/000003_align_usage_log_order_by.down.sql"
down_003_sql="$(sed 's/--.*$//' "$down_003" 2>/dev/null | tr -d ' \t\n\r;')"
assert_eq "000003 down has no executable SQL (irreversible marker)" "" "$down_003_sql"

# ── (C) specific known migrations exist ─────────────────────────────────
assert_eq "migration 000001_add_cost_source.up.sql exists" "true" \
    "$([ -f "$MIGRATIONS_DIR/000001_add_cost_source.up.sql" ] && echo true || echo false)"
assert_eq "migration 000002_add_request_id.up.sql exists" "true" \
    "$([ -f "$MIGRATIONS_DIR/000002_add_request_id.up.sql" ] && echo true || echo false)"
assert_eq "migration 000003_align_usage_log_order_by.up.sql exists" "true" \
    "$([ -f "$MIGRATIONS_DIR/000003_align_usage_log_order_by.up.sql" ] && echo true || echo false)"
assert_eq "migration 000004_create_billing_ledger_mv.up.sql exists" "true" \
    "$([ -f "$MIGRATIONS_DIR/000004_create_billing_ledger_mv.up.sql" ] && echo true || echo false)"

# ── (D) compose `migrate` service integration ───────────────────────────
compose_body="$(cat "$COMPOSE_FILE" 2>/dev/null || echo "")"
assert_contains "docker-compose.yml defines migrate service" "$compose_body" "  migrate:"
floating_tag="latest"
assert_contains "migrate service uses a pinned version tag" "$compose_body" "migrate/migrate:v4.19.1"
assert_not_contains "migrate service must use a pinned tag (not the floating tag)" "$compose_body" "migrate/migrate:${floating_tag}"
assert_contains "migrate service depends_on clickhouse" "$compose_body" "depends_on:"
assert_contains "migrate service restart: no" "$compose_body" 'restart: "no"'
assert_contains "migrate service on gateway network" "$compose_body" "- gateway"
assert_contains "migrate command has -path=/migrations/" "$compose_body" "-path=/migrations/"
assert_contains "migrate -database connects via compose DNS clickhouse:9000 (native protocol)" "$compose_body" "clickhouse:9000"
assert_not_contains "migrate -database does NOT use localhost" "$compose_body" "database=clickhouse://localhost"
assert_contains "migrate service mounts conf/migrations read-only" "$compose_body" "conf/migrations:/migrations:ro"

# ── (E) ansible orchestration integration ──────────────────────────────
ansible_body="$(cat "$ANSIBLE_FILE" 2>/dev/null || echo "")"
assert_contains "ansible runs golang-migrate via compose" "$ansible_body" "run --rm migrate up"
assert_contains "ansible migration task tagged [start]" "$ansible_body" "tags: [start]"

# line-order check: init.sql task MUST precede migration task
init_line=$(grep -n "Run ClickHouse init SQL" "$ANSIBLE_FILE" | head -1 | cut -d: -f1)
migrate_line=$(grep -n "run --rm migrate up" "$ANSIBLE_FILE" | head -1 | cut -d: -f1)
if [ -n "$init_line" ] && [ -n "$migrate_line" ]; then
    assert_eq "ansible: migrations run AFTER init.sql" "true" \
        "$([ "$migrate_line" -gt "$init_line" ] && echo true || echo false)"
else
    echo "[FAIL] could not locate init.sql or migrate task lines for ordering check"
    fail=$((fail + 1))
fi

# ── (F) Makefile integration ────────────────────────────────────────────
mk_body="$(cat "$MAKEFILE" 2>/dev/null || echo "")"
assert_contains "Makefile has ch-migrate target" "$mk_body" "ch-migrate:"
assert_contains "Makefile ch-migrate invokes compose run --rm migrate up" "$mk_body" "run --rm migrate up"
assert_contains "Makefile has ch-migrate-status target" "$mk_body" "ch-migrate-status:"
assert_contains "Makefile ch-migrate-status invokes migrate version" "$mk_body" "run --rm migrate version"
assert_not_contains "Makefile no longer references scripts/clickhouse-migrate.sh" "$mk_body" "clickhouse-migrate.sh"
assert_not_contains "Makefile no longer references scripts/ch-migrate.sh" "$mk_body" "ch-migrate.sh"

# ── (G) ARCHITECTURE.md references ──────────────────────────────────────
arch_body="$(cat "$ARCH_FILE" 2>/dev/null || echo "")"
assert_contains "ARCHITECTURE.md references golang-migrate" "$arch_body" "golang-migrate"
assert_contains "ARCHITECTURE.md references schema_migrations" "$arch_body" "schema_migrations"
assert_not_contains "ARCHITECTURE.md does NOT reference scripts/clickhouse-migrate.sh" "$arch_body" "scripts/clickhouse-migrate.sh"
assert_not_contains "ARCHITECTURE.md does NOT reference llm_gateway._migrations" "$arch_body" "llm_gateway._migrations"

echo ""
echo "test_migrations.sh: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi