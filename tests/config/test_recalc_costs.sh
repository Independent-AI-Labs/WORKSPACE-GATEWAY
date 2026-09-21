#!/bin/bash
set -euo pipefail

# tests/config/test_recalc_costs.sh
# Safety contract for the historical cost-recalculation tool
# (SPEC-COST-CALC section 6). Asserts: dry-run default, small-batch default,
# mandatory verified backup, audit-before-mutate, targeted idempotent
# mutations, shared cost formula, and that alias-dedupe no longer rewrites
# cost with a provider-agnostic formula. Does NOT require a running stack.

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
    _SELF="$SHG_SCRIPT_PATH"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/res/scripts/recalc-costs.sh"
RECALC_SQL_DIR="$REPO_ROOT/conf/sql/ops/recalc-costs"
BACKUP_SQL="$REPO_ROOT/conf/sql/ops/gateway-ch-backup/backup.sql"
LUA="$REPO_ROOT/res/scripts/cost/recalc.lua"
DEDUPE="$REPO_ROOT/res/scripts/dedupe-model-history.sh"
MAKEFILE="$REPO_ROOT/Makefile"
SPEC="$REPO_ROOT/docs/specifications/SPEC-COST-CALC.md"

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

# ── (A) files exist and are wired ───────────────────────────────────────
assert_eq "recalc-costs.sh exists" "true" \
    "$(if [ -f "$SCRIPT" ]; then printf 'true'; else printf 'false'; fi)"
assert_eq "recalc-costs.sh is executable" "true" \
    "$(if [ -x "$SCRIPT" ]; then printf 'true'; else printf 'false'; fi)"
assert_eq "recalc.lua exists" "true" \
    "$(if [ -f "$LUA" ]; then printf 'true'; else printf 'false'; fi)"

MK_RC=0
    MK_BODY="$(cat "$MAKEFILE")" || MK_RC=$?
assert_contains "Makefile exposes gw-recalc-costs" "$MK_BODY" "gw-recalc-costs:"
assert_contains "Makefile target invokes recalc-costs.sh" "$MK_BODY" "res/scripts/recalc-costs.sh"

# ── (B) dry-run and small-batch defaults ────────────────────────────────
SCRIPT_RC=0
    BODY="$(cat "$SCRIPT")" || SCRIPT_RC=$?

assert_contains "dry-run is the default (APPLY=false)" "$BODY" "APPLY=false"
assert_contains "dry run takes no backup and writes nothing" "$BODY" "DRY RUN -- no backup taken, nothing written"
assert_contains "small batch default LIMIT=100" "$BODY" "LIMIT=100"
assert_contains "--all with --apply requires --confirm-all" "$BODY" "REFUSING --apply --all without --confirm-all"

# ── (C) mandatory verified backup before any write ──────────────────────
RECALC_SQL_BODY="$(cat "$RECALC_SQL_DIR"/*.sql)"
assert_contains "takes a full-database backup" "$(cat "$BACKUP_SQL")" "BACKUP DATABASE"
assert_contains "verifies backup status" "$BODY" "BACKUP_CREATED"
assert_contains "aborts when backup is unverified" "$BODY" "not BACKUP_CREATED); aborting"
# backup render call appears before the first mutation render call
backup_line=$(grep -n "ops/gateway-ch-backup/backup.sql" "$SCRIPT" | sed -n '1p' | cut -d: -f1)
alter_line=$(grep -n "ops/recalc-costs/alter-provider.sql" "$SCRIPT" | sed -n '1p' | cut -d: -f1)
assert_eq "backup happens before the first mutation" "true" \
    "$(if [ -n "$backup_line" ] && [ -n "$alter_line" ] && [ "$backup_line" -lt "$alter_line" ]; then printf 'true'; else printf 'false'; fi)"

# ── (D) audit-before-mutate, targeted, idempotent ───────────────────────
assert_contains "writes cost_recalc_audit" "$BODY" "cost_recalc_audit"
assert_contains "reprices every provenance by default" "$BODY" 'SOURCES="unknown,provider_override,models_dev"'
assert_contains "mutation is scoped by source" "$RECALC_SQL_BODY" "AND cost_source IN ({{ SOURCE_SQL }})"
assert_contains "cost mutation is idempotent (skips already-correct rows)" "$RECALC_SQL_BODY" 'AND (abs(cost - ({{ EXPR }})) > {{ EPSILON }} OR cost_source != {{ NEW_SOURCE }})'
assert_contains "provider backfill is one bulk UPDATE per mapping" "$RECALC_SQL_BODY" "UPDATE provider_id = {{ NEW_PID }}"
assert_contains "cost revalue writes the resolved provenance" "$RECALC_SQL_BODY" 'UPDATE cost = {{ EXPR }}, cost_source = {{ NEW_SOURCE }}'
if [[ "$RECALC_SQL_BODY" == *"AND timestamp = toDateTime64("* ]]; then
    echo "[FAIL] recalc must not mutate row-by-row (bulk groups expected)"
    fail=$((fail + 1))
else
    echo "[PASS] recalc mutates in bulk, not row-by-row"
    pass=$((pass + 1))
fi
audit_line=$(grep -n "ops/recalc-costs/insert-audit.sql" "$SCRIPT" | sed -n '1p' | cut -d: -f1)
assert_eq "audit insert precedes the first mutation" "true" \
    "$(if [ -n "$audit_line" ] && [ -n "$alter_line" ] && [ "$audit_line" -lt "$alter_line" ]; then printf 'true'; else printf 'false'; fi)"

# ── (E) one shared formula ──────────────────────────────────────────────
assert_contains "recalc.lua reuses cost_calc.compute_cost" "$(cat "$LUA")" 'require("cost_calc")'
assert_contains "recalc.lua reuses model_registry.canonical" "$(cat "$LUA")" 'require("model_registry")'
# Corrections travel on a non-whitespace separator so an empty request_id
# (migrated rows) is not collapsed by the shell's tab-IFS read.
assert_contains "recalc.lua emits unit-separated corrections" "$(cat "$LUA")" '\31'
assert_contains "consumer reads corrections with unit-separator IFS" "$BODY" "IFS=\$'\\x1f' read -r eid"

# ── (F) alias dedupe no longer rewrites cost ────────────────────────────
DEDUPE_RC=0
    DEDUPE_BODY="$(cat "$DEDUPE")" || DEDUPE_RC=$?
if [[ "$DEDUPE_BODY" == *"cost_source = 'computed'"* ]]; then
    echo "[FAIL] dedupe must not rewrite cost itself"
    fail=$((fail + 1))
else
    echo "[PASS] dedupe defers cost repair to recalc-costs.sh"
    pass=$((pass + 1))
fi
assert_contains "dedupe points at the dedicated tool" "$DEDUPE_BODY" "cost repair is owned by res/scripts/recalc-costs.sh"

# ── (G) the spec documents the tool ─────────────────────────────────────
assert_contains "SPEC-COST-CALC documents recalc-costs.sh" "$(cat "$SPEC")" "recalc-costs.sh"

echo ""
echo "test_recalc_costs.sh: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi
