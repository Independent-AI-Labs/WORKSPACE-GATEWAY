#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CI_REPO="$REPO_ROOT/../CI"
PRE_COMMIT_CONFIG="$REPO_ROOT/.pre-commit-config.yaml"

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

grep_config_ref() {
    local pattern="$1"
    local desc="$2"
    if grep -qE "$pattern" "$PRE_COMMIT_CONFIG" 2>/dev/null; then
        check "$desc" "0"
    else
        check "$desc" "1"
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

if [ ! -f "$PRE_COMMIT_CONFIG" ]; then
    check ".pre-commit-config.yaml exists" "1"
else
    check ".pre-commit-config.yaml exists" "0"
    grep_config_ref 'id: check-banned-words' \
        "pre-commit config defines check-banned-words"
    grep_config_ref 'id: block-sensitive-files' \
        "pre-commit config defines block-sensitive-files"
    grep_config_ref 'id: gitleaks' \
        "pre-commit config defines gitleaks"
    grep_config_ref 'id: ci-check-push' \
        "pre-commit config defines ci-check-push (pre-push stage)"
    grep_config_ref 'id: check-dead-code' \
        "pre-commit config defines check-dead-code (pre-push stage)"
    grep_config_ref 'id: check-dependency-versions' \
        "pre-commit config defines check-dependency-versions"
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