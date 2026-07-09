#!/bin/bash
# yaml_helpers.sh
# Shared YAML-to-JSON conversion helper for test scripts.
# Uses containerized Lua lyaml (via APISIX image) - no Python required.
#
# Usage:
#   source "$(dirname "$0")/yaml_helpers.sh"
#   JSON_DATA=$(yaml_to_json "$YAML_FILE")
#   if [ $? -ne 0 ]; then
#     echo "[FAIL] YAML parse error"
#     ...
#   fi

# version_ge v1 v2 - returns 0 (true) if semver v1 >= v2, else 1.
# Uses awk to avoid bash array pitfalls under set -u.
version_ge() {
    awk -v a="$1" -v b="$2" 'BEGIN{
        n=split(a,va,"."); m=split(b,vb,".");
        for(i=1;i<=(n>m?n:m);i++){
            x=va[i]+0; y=vb[i]+0;
            if(x>y) exit 0;
            if(x<y) exit 1;
        }
        exit 0
    }'
}

# Converts a YAML file to compact JSON on stdout.
# Exit 0 on success, non-zero on parse failure.
yaml_to_json() {
  local yaml_file="$1"
  local tmp_dir

  tmp_dir="$(mktemp -d)"
  chmod 755 "$tmp_dir"

  # Copy YAML file into temp dir for container access
  cp "$yaml_file" "$tmp_dir/input.yaml"

  podman run --rm \
    -e 'LUA_PATH=/usr/local/apisix/deps/share/lua/5.1/?.lua;/usr/local/apisix/deps/share/lua/5.1/?/init.lua;;' \
    -e 'LUA_CPATH=/usr/local/apisix/deps/lib/lua/5.1/?.so;;' \
    -v "$tmp_dir:/yaml-tmp:ro" \
    --entrypoint /usr/local/openresty/luajit/bin/luajit \
    apache/apisix:3.17.0-debian \
    -e 'local y=require("lyaml"); local c=require("cjson.safe"); local f=io.open("/yaml-tmp/input.yaml"); if not f then io.stderr:write("cannot open\n"); os.exit(1) end; local data=y.load(f:read("*a")); f:close(); local j=c.encode(data); if not j then io.stderr:write("encode failed\n"); os.exit(1) end; io.write(j); io.write("\n")' \
    2>/dev/null

  local ret=$?
  rm -rf "$tmp_dir"
  return $ret
}
