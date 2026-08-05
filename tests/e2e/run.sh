#!/bin/bash
set -euo pipefail

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
    _SELF="$SHG_SCRIPT_PATH"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ "${1:-}" = "--live" ]; then
    export RUN_LIVE_API_TESTS=1
fi

if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    source "$REPO_ROOT/.env" || exit 1
    set +a
fi

if [ -z "${OPENCODE_API_KEY:-}" ]; then
    echo "[SKIP] OPENCODE_API_KEY not set, skipping all E2E tests"
    exit 0
fi

if [ -z "${GATEWAY_API_KEY:-}" ]; then
    echo "[SKIP] GATEWAY_API_KEY not set, skipping all E2E tests"
    exit 0
fi

apisix_check=$(mktemp)
curl_code=$(curl -s -o "$apisix_check" -w "%{http_code}" --max-time 5 \
    http://localhost:9080/ || echo "000")
rm -f "$apisix_check"

if [ "$curl_code" = "000" ]; then
    echo "[SKIP] APISIX not reachable on port 9080, skipping all E2E tests"
    exit 0
fi

pass=0
fail=0

for test_script in test_zen_chat.sh test_zen_stream.sh test_redact_e2e.sh test_stream_redact.sh test_invalid_model.sh; do
    echo ""
    echo "=== Running $test_script ==="
    if bash "$SCRIPT_DIR/$test_script" ${1:-}; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
    fi
done

echo ""
echo "E2E tests: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi
