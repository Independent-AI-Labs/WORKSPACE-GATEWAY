#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CI_REPO="$REPO_ROOT/../CI"

pass=0
fail=0

check() {
    local desc="$1"
    local result="$2"
    if [ "$result" = "0" ]; then
        echo "[PASS] $desc"
        pass=$((pass + 1))
    else
        echo "[FAIL] $desc"
        fail=$((fail + 1))
    fi
}

PRE_COMMIT="$REPO_ROOT/.git/hooks/pre-commit"
PRE_PUSH="$REPO_ROOT/.git/hooks/pre-push"

if [ -x "$PRE_COMMIT" ]; then
    check "pre-commit exists and is executable" "0"
else
    check "pre-commit exists and is executable" "1"
fi

if [ -x "$PRE_PUSH" ]; then
    check "pre-push exists and is executable" "0"
else
    check "pre-push exists and is executable" "1"
fi

grep -q 'check-banned-words' "$PRE_COMMIT" 2>/dev/null
check "pre-commit references check-banned-words" "$?"

grep -q 'block-sensitive-files' "$PRE_COMMIT" 2>/dev/null
check "pre-commit references block-sensitive-files" "$?"

grep -q 'gitleaks' "$PRE_COMMIT" 2>/dev/null
check "pre-commit references gitleaks" "$?"

grep -q 'ci-check-push' "$PRE_PUSH" 2>/dev/null
check "pre-push references ci-check-push" "$?"

grep -q 'check-dead-code' "$PRE_PUSH" 2>/dev/null
check "pre-push references check-dead-code" "$?"

grep -q 'check-dependency-versions\|check_dependency_versions' "$PRE_COMMIT" 2>/dev/null
check "pre-commit references check-dependency-versions" "$?"

if [ -f "$REPO_ROOT/.pre-commit-config.yaml" ]; then
    check ".pre-commit-config.yaml exists" "0"
else
    check ".pre-commit-config.yaml exists" "1"
fi

if [ -f "$CI_REPO/config/banned_words.yaml" ]; then
    check "banned_words.yaml exists in CI repo" "0"
else
    check "banned_words.yaml exists in CI repo" "1"
fi

echo ""
echo "CI hook tests: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi