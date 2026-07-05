#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass=0
fail=0

assert_eq() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "[PASS] $desc"
        pass=$((pass + 1))
    else
        echo "[FAIL] $desc -- expected: $expected, actual: $actual"
        fail=$((fail + 1))
    fi
}

summary() {
    echo ""
    echo "test_patterns_json.sh: $pass passed, $fail failed"
    if [ "$fail" -gt 0 ]; then
        exit 1
    fi
}

PATTERNS_JSON="$REPO_ROOT/conf/redact-patterns.json"

jq empty "$PATTERNS_JSON" 2>/dev/null
ret=$?
if [ "$ret" -ne 0 ]; then
    echo "[FAIL] Valid JSON"
    fail=$((fail + 1))
    summary
fi

assert_eq "Valid JSON" "ok" "ok"

REGEX_COUNT=$(jq '.regex | length' "$PATTERNS_JSON")
assert_eq "regex array has 6 entries" "6" "$REGEX_COUNT"

DICT_COUNT=$(jq '.dictionary | length' "$PATTERNS_JSON")
assert_eq "dictionary array has 2 entries" "2" "$DICT_COUNT"

LUHN_CHECK=$(jq -r '.regex[] | select(.kind=="credit_card") | .luhn_check' "$PATTERNS_JSON")
assert_eq "credit_card entry has luhn_check: true" "true" "$LUHN_CHECK"

REGX_ENTRY_COUNT=$(jq '.regex | length' "$PATTERNS_JSON")
HAS_KIND_COUNT=$(jq '[.regex[] | select(.kind != null)] | length' "$PATTERNS_JSON")
assert_eq "Each regex entry has kind field" "$REGX_ENTRY_COUNT" "$HAS_KIND_COUNT"

HAS_PATTERN_COUNT=$(jq '[.regex[] | select(.pattern != null)] | length' "$PATTERNS_JSON")
assert_eq "Each regex entry has pattern field" "$REGX_ENTRY_COUNT" "$HAS_PATTERN_COUNT"

summary