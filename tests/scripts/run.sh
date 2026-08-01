#!/bin/bash
set -euo pipefail

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
    _SELF="$SHG_SCRIPT_PATH"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"

pass=0
fail=0

for test_script in test_opencode_provider_login.sh; do
    echo ""
    echo "--- $test_script ---"
    if bash "$SCRIPT_DIR/$test_script"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
    fi
done

echo ""
echo "Scripts tests: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi
