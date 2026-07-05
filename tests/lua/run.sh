#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

IMAGE="apache/apisix:3.17.0-debian"

echo "[run.sh] repo root: $REPO_ROOT"
echo "[run.sh] running Lua unit tests via podman..."

set +e
podman run --rm \
  -v "$REPO_ROOT/plugins/custom:/plugins/custom:ro" \
  -v "$REPO_ROOT:/workspace:ro" \
  --entrypoint /usr/bin/resty \
  "$IMAGE" \
  -I /plugins/custom \
  /workspace/tests/lua/test_redact_lib.lua
ret=$?
set -e

echo "[run.sh] resty exit code: $ret"
if [ "$ret" -ne 0 ]; then
  echo "[run.sh] FAIL: Lua unit tests failed."
  exit "$ret"
fi

echo "[run.sh] PASS: Lua unit tests succeeded."