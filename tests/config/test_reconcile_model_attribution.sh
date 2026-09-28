#!/bin/bash
set -euo pipefail

# tests/config/test_reconcile_model_attribution.sh
# Structure guard for the idempotent model-attribution reconciler
# (SPEC-USEFULNESS-TELEMETRY section 6, REQ FR-9.8/FR-9.9). Static checks
# only; the live repair runs in dev via make gw-reconcile-model-attribution.

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
    _SELF="$SHG_SCRIPT_PATH"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/res/scripts/reconcile-model-attribution.sh"
OPS="$REPO_ROOT/conf/sql/ops/reconcile-model-attribution"
MAKEFILE="$REPO_ROOT/Makefile"
UNIT="$REPO_ROOT/res/ansible/templates/gateway-model-attribution-check.service.j2"
INIT="$REPO_ROOT/conf/sql/clickhouse-init.sql"
MIG12="$REPO_ROOT/conf/sql/migrations/000012_add_cache_write_tokens.up.sql"

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

assert_file_has() {
    local desc="$1" file="$2" needle="$3"
    if grep -qF -- "$needle" "$file"; then
        echo "[PASS] $desc"; pass=$((pass + 1))
    else
        echo "[FAIL] $desc -- missing: [$needle]"; fail=$((fail + 1))
    fi
}

assert_file_absent() {
    local desc="$1" file="$2" needle="$3"
    if grep -qF -- "$needle" "$file"; then
        echo "[FAIL] $desc -- unexpected: [$needle]"; fail=$((fail + 1))
    else
        echo "[PASS] $desc"; pass=$((pass + 1))
    fi
}

assert_eq "reconcile script exists" "yes" "$(if [ -f "$SCRIPT" ]; then printf yes; else printf no; fi)"
assert_eq "reconcile script is executable" "yes" "$(if [ -x "$SCRIPT" ]; then printf yes; else printf no; fi)"

for f in before-snapshot after-snapshot create-backfill drop-backfill \
         drop-backfill-final exchange-backfill insert-request-log insert-usage-log \
         insert-billing-ledger mv-create mv-drop remaining-count row-count \
         shadow-count shadow-report shadow-sample; do
    assert_eq "ops SQL $f.sql exists" "yes" "$(if [ -f "$OPS/$f.sql" ]; then printf yes; else printf no; fi)"
done

# Shared shadow templates parameterize the table name.
assert_file_has "create uses {{ TABLE }}" "$OPS/create-backfill.sql" '{{ DB }}.{{ TABLE }}_backfill AS {{ DB }}.{{ TABLE }}'
assert_file_has "swap uses EXCHANGE TABLES" "$OPS/exchange-backfill.sql" 'EXCHANGE TABLES {{ DB }}.{{ TABLE }} AND {{ DB }}.{{ TABLE }}_backfill'
assert_file_has "drop is IF EXISTS" "$OPS/drop-backfill.sql" 'TABLE IF EXISTS'
assert_file_has "final drop removes only the shadow" "$OPS/drop-backfill-final.sql" 'TABLE {{ DB }}.{{ TABLE }}_backfill'

# Every insert canonicalizes the local raw through the registry map and only
# repairs empty/garbage values (idempotent), preserving schema with EXCEPT/REPLACE.
for f in insert-request-log insert-usage-log insert-billing-ledger; do
    assert_file_has "$f uses registry CANON_EXPR" "$OPS/$f.sql" '{{ CANON_EXPR }}'
    assert_file_has "$f preserves all columns via EXCEPT/REPLACE" "$OPS/$f.sql" 'REPLACE ('
    assert_file_has "$f guards garbage raw shape" "$OPS/$f.sql" "match(model_raw, '^[A-Za-z0-9._/-]+\$')"
done
assert_file_has "request insert joins usage_log" "$OPS/insert-request-log.sql" '{{ DB }}.usage_log'
assert_file_has "usage insert joins request_log by request_id" "$OPS/insert-usage-log.sql" 'u.request_id = r.request_id'
assert_file_has "billing insert joins usage_log by event_id" "$OPS/insert-billing-ledger.sql" 'b.event_id = u.event_id'

# MV is recreated from the committed definition, never from the live
# create_table_query (whose stored SELECT backslash-escapes quotes).
assert_file_has "mv-create defines the MV" "$OPS/mv-create.sql" 'MATERIALIZED VIEW IF NOT EXISTS {{ DB }}.billing_ledger_mv'
assert_file_has "mv-create targets billing_ledger" "$OPS/mv-create.sql" 'TO {{ DB }}.billing_ledger'
assert_file_has "mv-create reads usage_log" "$OPS/mv-create.sql" 'FROM {{ DB }}.usage_log;'
assert_file_has "script uses mv-create for restore" "$SCRIPT" 'mv-create.sql'
assert_file_absent "script does not use the removed capture file" "$SCRIPT" 'mv-ddl.sql'

# Safety + idempotency contract.
assert_file_has "dry-run by default" "$SCRIPT" 'APPLY=false'
assert_file_has "apply gate present" "$SCRIPT" 'if ! $APPLY'
assert_file_has "shadow row count verified" "$SCRIPT" 'shadow-count.sql'
assert_file_has "aborts on a short shadow" "$SCRIPT" 'nothing swapped'
assert_file_has "re-checks source==shadow before swap" "$SCRIPT" 'changed under us'
assert_file_has "MV restore trap installed" "$SCRIPT" 'trap restore_mv EXIT'
assert_file_has "per-table build+swap order" "$SCRIPT" 'build_shadow request_log'

assert_file_has "make target wired" "$MAKEFILE" 'gw-reconcile-model-attribution:'
assert_file_has "make target gates on APPLY" "$MAKEFILE" '$(if $(APPLY),--apply)'

# Read-only drift guard: the same script, --check, exits nonzero on any
# cross-table/signal disagreement so attribution drops fail loudly.
assert_file_has "drift-check report exists" "$OPS/drift-check.sql" 'AS signals_mismatch'
assert_file_has "drift-check covers usage vs request" "$OPS/drift-check.sql" 'AS usage_mismatch'
assert_file_has "drift-check uses the raw shape guard" "$OPS/drift-check.sql" "match(model_raw, '^[A-Za-z0-9._/-]+\$')"
assert_file_has "script parses --check" "$SCRIPT" '--check) CHECK=true'
assert_file_has "script exits nonzero on drift" "$SCRIPT" 'attributable mismatch'
assert_file_has "make check target wired" "$MAKEFILE" 'gw-check-model-attribution:'
assert_file_has "check unit runs --check" "$UNIT" 'reconcile-model-attribution.sh --check'

# mv-create.sql must match the canonical MV definition in clickhouse-init.sql
# (the provisioning path) after substituting the DB template variable.
norm_block() {
    sed -n '/CREATE MATERIALIZED VIEW IF NOT EXISTS .*billing_ledger_mv/,/FROM .*usage_log;/p' "$1" \
        | sed 's/{{ DB }}\./llm_gateway./g; s/[[:space:]]\+/ /g; s/^ //; s/ $//' | sort
}
INIT_MV="$(norm_block "$INIT")"
CREATE_MV="$(norm_block "$OPS/mv-create.sql")"
assert_eq "mv-create matches clickhouse-init MV block" "$INIT_MV" "$CREATE_MV"
assert_eq "mv-create matches migration 000012 MV block" "$(norm_block "$MIG12")" "$CREATE_MV"

echo ""
echo "test_reconcile_model_attribution.sh: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi
