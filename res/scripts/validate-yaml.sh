#!/bin/bash
# validate-yaml.sh: validate YAML files with containerized Lua lyaml
# (APISIX image) - same check the Makefile lint gate runs.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

tmpfile=$(mktemp)
trap 'rm -f $tmpfile' EXIT
for f in conf/*.yaml res/docker/*.yml res/ansible/*.yml tests/*.yml; do
	[ -f "$f" ] || continue
	echo "  checking $f"
	podman run --rm \
		-e 'LUA_PATH=/usr/local/apisix/deps/share/lua/5.1/?.lua;/usr/local/apisix/deps/share/lua/5.1/?/init.lua;;' \
		-e 'LUA_CPATH=/usr/local/apisix/deps/lib/lua/5.1/?.so;;' \
		-v "$PWD/$f:/check.yaml:ro" \
		--entrypoint /usr/local/openresty/luajit/bin/luajit \
		apache/apisix:3.17.0-debian \
		-e 'local y=require("lyaml"); local f=io.open("/check.yaml"); if not f then io.stderr:write("cannot open\n"); os.exit(1) end; y.load(f:read("*a")); f:close()' \
		2>$tmpfile || { echo "FAIL: $f"; cat $tmpfile 1>&2; exit 1; }
done
rm -f $tmpfile
