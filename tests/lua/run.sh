#!/bin/bash
set -euo pipefail

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
    _SELF="$SHG_SCRIPT_PATH"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../config/yaml_helpers.sh
source "$REPO_ROOT/tests/config/yaml_helpers.sh" || exit 1

IMAGE="apache/apisix:3.18.0-debian"

# Custom modules require each other by their deployed dotted name
# (apisix.plugins.<module>). Expose the repo's flat plugins/custom tree under
# a matching directory so the plain-LuaJIT harness resolves the same single
# require path production uses.
MODULE_PATH_DIR="$(mktemp -d)"
mkdir -p "$MODULE_PATH_DIR/apisix/plugins"
for _mod in "$REPO_ROOT"/plugins/custom/*.lua; do
  ln -sf "/plugins/custom/$(basename "$_mod")" \
    "$MODULE_PATH_DIR/apisix/plugins/$(basename "$_mod")"
done
chmod -R a+rX "$MODULE_PATH_DIR"
trap 'rm -rf "$MODULE_PATH_DIR"' EXIT

echo "[run.sh] repo root: $REPO_ROOT"
echo "[run.sh] running Lua unit tests via podman..."

OVERALL_RET=0

for test_file in test_redact_lib.lua test_sse_usage_lib.lua test_oauth_jwt.lua test_oauth_broker.lua test_oauth_session.lua test_oauth_device.lua test_provider_oauth.lua test_provider_pricing.lua test_provider_sync.lua test_upstream_pool_lib.lua test_usefulness_cruncher.lua test_cost_recalc.lua; do
  echo ""
  echo "[run.sh] running $test_file..."
  ret=0
  "$PODMAN_BIN" run --rm \
    -v "$REPO_ROOT/plugins/custom:/plugins/custom:ro" \
    -v "$MODULE_PATH_DIR:/module-path:ro" \
    -v "$REPO_ROOT:/workspace:ro" \
    --entrypoint /usr/bin/resty \
    "$IMAGE" \
     -I /module-path \
     -I /plugins/custom \
     -I /workspace/tests/lua \
     -I /workspace/res/scripts/usefulness \
     -I /workspace/res/scripts/cost \
    "/workspace/tests/lua/$test_file" || ret=$?
  echo "[run.sh] $test_file exit code: $ret"
  if [ "$ret" -ne 0 ]; then
    OVERALL_RET=$ret
  fi
done

echo ""
echo "[run.sh] overall exit code: $OVERALL_RET"
if [ "$OVERALL_RET" -ne 0 ]; then
  echo "[run.sh] FAIL: Lua unit tests failed."
  exit "$OVERALL_RET"
fi

echo "[run.sh] PASS: Lua unit tests succeeded."
