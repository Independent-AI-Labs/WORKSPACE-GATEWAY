#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
