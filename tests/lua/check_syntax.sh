#!/bin/bash
set -euo pipefail

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
  _SELF="$SHG_SCRIPT_PATH"
fi
REPO_ROOT="$(cd "$(dirname "$_SELF")/../.." && pwd)"
# shellcheck source=../config/yaml_helpers.sh
source "$REPO_ROOT/tests/config/yaml_helpers.sh"

for file in "$REPO_ROOT"/plugins/custom/*.lua; do
  [ -f "$file" ] || continue
  name="$(basename "$file")"
  echo "  checking $name"
  "$PODMAN_BIN" run --rm \
    -v "$REPO_ROOT/plugins/custom:/plugins/custom:ro" \
    --entrypoint /usr/bin/resty \
    apache/apisix:3.17.0-debian \
    -e "local f, err = loadfile('/plugins/custom/$name'); if not f then error(err) end"
done
