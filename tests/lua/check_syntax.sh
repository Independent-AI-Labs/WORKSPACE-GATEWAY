#!/bin/bash
set -euo pipefail

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
  _SELF="$SHG_SCRIPT_PATH"
fi
REPO_ROOT="$(cd "$(dirname "$_SELF")/../.." && pwd)"
# shellcheck source=../config/yaml_helpers.sh
source "$REPO_ROOT/tests/config/yaml_helpers.sh" || exit 1

for file in "$REPO_ROOT"/plugins/custom/*.lua "$REPO_ROOT"/res/scripts/usefulness/*.lua "$REPO_ROOT"/res/scripts/cost/*.lua; do
  [ -f "$file" ] || continue
  name="$(basename "$file")"
  case "$file" in
    */plugins/custom/*) container_path="/plugins/custom/$name" ;;
    */usefulness/*) container_path="/usefulness/$name" ;;
    *) container_path="/cost/$name" ;;
  esac
  echo "  checking $name"
  "$PODMAN_BIN" run --rm \
    -v "$REPO_ROOT/plugins/custom:/plugins/custom:ro" \
    -v "$REPO_ROOT/res/scripts/usefulness:/usefulness:ro" \
    -v "$REPO_ROOT/res/scripts/cost:/cost:ro" \
    --entrypoint /usr/bin/resty \
    apache/apisix:3.18.0-debian \
    -e "local f, err = loadfile('$container_path'); if not f then error(err) end"
done
