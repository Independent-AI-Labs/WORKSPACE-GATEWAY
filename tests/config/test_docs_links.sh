#!/bin/bash
set -euo pipefail

# tests/config/test_docs_links.sh
# Documentation contract:
#   - every REQ-*.md has a companion SPEC-*.md and links it, and vice-versa
#   - every REQ/SPEC is indexed in docs/README.md
#   - every REQ carries the template sections and covers its FR ids in the
#     Verification Matrix / Implementation Status
#   - architecture/AUTH-MODEL.md exists and is indexed in architecture/README.md
# No network or running services required.

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
    _SELF="$SHG_SCRIPT_PATH"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REQ_DIR="$REPO_ROOT/docs/requirements"
SPEC_DIR="$REPO_ROOT/docs/specifications"
DOCS_README="$REPO_ROOT/docs/README.md"
ARCH_README="$REPO_ROOT/docs/architecture/README.md"
AUTH_MODEL="$REPO_ROOT/docs/architecture/AUTH-MODEL.md"

pass=0
fail=0

ok()   { echo "[PASS] $1"; pass=$((pass + 1)); }
bad()  { echo "[FAIL] $1"; fail=$((fail + 1)); }

# section_body <file> <start-heading-regex> <end-heading-regex>
section_body() {
    awk -v s="$2" -v e="$3" '$0 ~ s {f=1; next} $0 ~ e {f=0} f' "$1"
}

# ── (A) REQ <-> SPEC pairing and cross-links ───────────────────────────
for req in "$REQ_DIR"/REQ-*.md; do
    base="${req##*/}"
    stem="${base#REQ-}"
    stem="${stem%.md}"
    spec="$SPEC_DIR/SPEC-$stem.md"

    if [ -f "$spec" ]; then
        ok "REQ-$stem has companion SPEC-$stem.md"
    else
        bad "REQ-$stem missing companion SPEC-$stem.md"
        continue
    fi

    if [ -n "$(sed -n "/specifications\/SPEC-$stem.md/p" "$req")" ]; then
        ok "REQ-$stem links SPEC-$stem.md"
    else
        bad "REQ-$stem does not link SPEC-$stem.md"
    fi

    if [ -n "$(sed -n "/requirements\/REQ-$stem.md/p" "$spec")" ]; then
        ok "SPEC-$stem links REQ-$stem.md"
    else
        bad "SPEC-$stem does not link REQ-$stem.md"
    fi
done

# ── (B) index coverage in docs/README.md ───────────────────────────────
for req in "$REQ_DIR"/REQ-*.md; do
    base="${req##*/}"
    if [ -n "$(sed -n "/$base/p" "$DOCS_README")" ]; then
        ok "docs/README.md indexes $base"
    else
        bad "docs/README.md does not index $base"
    fi
done

for spec in "$SPEC_DIR"/SPEC-*.md; do
    base="${spec##*/}"
    if [ -n "$(sed -n "/$base/p" "$DOCS_README")" ]; then
        ok "docs/README.md indexes $base"
    else
        bad "docs/README.md does not index $base"
    fi
done

# ── (C) canonical-template REQ sections + FR coverage ──────────────────
# Enforcement is opt-in by template presence: a REQ that carries both a
# "Functional Requirements" and a "Verification Matrix" heading (the current
# contract) must also carry "Implementation Status" and map every FR id.
# Pre-canonical docs (e.g. older provider REQs with their own section layout)
# are outside this contract and are not structurally enforced here.
for req in "$REQ_DIR"/REQ-*.md; do
    base="${req##*/}"
    stem="${base%.md}"

    has_fr_heading=0
    has_matrix_heading=0
    [ -n "$(sed -n '/^#.*Functional Requirements/p' "$req")" ] && has_fr_heading=1
    [ -n "$(sed -n '/^#.*Verification Matrix/p' "$req")" ] && has_matrix_heading=1

    if [ "$has_fr_heading" -eq 0 ] || [ "$has_matrix_heading" -eq 0 ]; then
        echo "[SKIP] $stem not on the canonical 8-section template"
        continue
    fi

    if [ -n "$(sed -n '/^#.*Implementation Status/p' "$req")" ]; then
        ok "$stem has an Implementation Status section"
    else
        bad "$stem missing an Implementation Status section"
    fi

    coverage="$(section_body "$req" 'Verification Matrix' 'Implementation Status')$(section_body "$req" 'Implementation Status' '^(## |# )')"
    missing=""
    while IFS= read -r fr; do
        [ -n "$fr" ] || continue
        case "$fr" in FR-N) continue ;; esac
        case "$coverage" in
            *"$fr"*) ;;
            *) missing="$missing $fr" ;;
        esac
    done < <(sed -n 's/^#* *\(FR-[0-9][0-9]*\):.*/\1/p' "$req")

    if [ -z "$missing" ]; then
        ok "$stem covers all FR ids in Verification Matrix / Implementation Status"
    else
        bad "$stem FR ids not covered:$missing"
    fi
done

# ── (D) architecture AUTH-MODEL ────────────────────────────────────────
if [ -f "$AUTH_MODEL" ]; then
    ok "architecture/AUTH-MODEL.md exists"
else
    bad "architecture/AUTH-MODEL.md missing"
fi

if [ -n "$(sed -n '/AUTH-MODEL.md/p' "$ARCH_README")" ]; then
    ok "architecture/README.md indexes AUTH-MODEL.md"
else
    bad "architecture/README.md does not index AUTH-MODEL.md"
fi

# ── (E) retired predecessors remain split and linked ───────────────────
req_ea="$REQ_DIR/REQ-ENTERPRISE-AUTH.md"
spec_ea="$SPEC_DIR/SPEC-ENTERPRISE-AUTH.md"

if [ -n "$(sed -n '/Status:\*\* Retired/p' "$req_ea")" ]; then
    ok "REQ-ENTERPRISE-AUTH.md marked Retired"
else
    bad "REQ-ENTERPRISE-AUTH.md not marked Retired"
fi
for tgt in REQ-KEYCLOAK-INTEGRATION REQ-AI-PROXY; do
    if [ -n "$(sed -n "/$tgt/p" "$req_ea")" ]; then
        ok "REQ-ENTERPRISE-AUTH.md points to $tgt"
    else
        bad "REQ-ENTERPRISE-AUTH.md does not point to $tgt"
    fi
done

if [ -n "$(sed -n '/Status:\*\* Retired/p' "$spec_ea")" ]; then
    ok "SPEC-ENTERPRISE-AUTH.md marked Retired"
else
    bad "SPEC-ENTERPRISE-AUTH.md not marked Retired"
fi
for tgt in SPEC-KEYCLOAK-INTEGRATION SPEC-AI-PROXY; do
    if [ -n "$(sed -n "/$tgt/p" "$spec_ea")" ]; then
        ok "SPEC-ENTERPRISE-AUTH.md points to $tgt"
    else
        bad "SPEC-ENTERPRISE-AUTH.md does not point to $tgt"
    fi
done

echo ""
echo "test_docs_links.sh: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi
