#!/usr/bin/env bash
# Shared helpers for opencode-provider-login.sh. Sourced, not executed:
# JSONC comment stripping and auth-plugin registration only.

# Strip // and /* */ comments from JSONC while respecting string literals.
# Slow but dependency-free; works for the small OpenCode config files.
strip_jsonc_comments() {
  local input="$1"
  local output=""
  local in_string=0
  local in_line_comment=0
  local in_block_comment=0
  local escaped=0
  local len=${#input}

  for (( i=0; i<len; i++ )); do
    local ch="${input:$i:1}"
    if [ $in_string -eq 1 ]; then
      if [ $escaped -eq 1 ]; then
        escaped=0
      elif [ "$ch" = "\\" ]; then
        escaped=1
      elif [ "$ch" = '"' ]; then
        in_string=0
      fi
      output="${output}${ch}"
    elif [ $in_line_comment -eq 1 ]; then
      if [ "$ch" = $'\n' ]; then
        in_line_comment=0
        output="${output}${ch}"
      fi
    elif [ $in_block_comment -eq 1 ]; then
      if [ "$ch" = "*" ]; then
        local next="${input:$((i+1)):1}"
        if [ "$next" = "/" ]; then
          in_block_comment=0
          i=$((i+1))
        fi
      fi
    else
      if [ "$ch" = '"' ]; then
        in_string=1
        output="${output}${ch}"
      elif [ "$ch" = "/" ]; then
        local next="${input:$((i+1)):1}"
        if [ "$next" = "/" ]; then
          in_line_comment=1
          i=$((i+1))
        elif [ "$next" = "*" ]; then
          in_block_comment=1
          i=$((i+1))
        else
          output="${output}${ch}"
        fi
      else
        output="${output}${ch}"
      fi
    fi
  done
  echo "$output"
}

# --- OpenCode auth plugin registration (FR-5.7) ---
# Registers the gateway-owned auth plugin for OAuth providers. OpenCode
# collapses config plugin entries that share one target file (last entry
# wins), so each provider gets a tiny generated wrapper with baked options
# under ~/.config/opencode/plugin/ and a plain string spec entry. Idempotent:
# the wrapper is rewritten and the entry replaced in place; unrelated plugin
# entries are preserved; providers without OAuth methods get neither.
# Globals read: PROVIDER_ID, GATEWAY, CONFIG_FILE, OPENCODE_RESP, REPO_ROOT,
# MERGED_CONFIG (updated in place).
register_auth_plugin() {
  local engine plugin_dir wrapper method_count fileurl
  engine="$REPO_ROOT/res/opencode-plugin/workspace-gateway-auth.ts"
  plugin_dir="$(dirname "$CONFIG_FILE")/plugin"
  wrapper="$plugin_dir/wg-auth-${PROVIDER_ID}.ts"
  fileurl="file://${engine}"
  method_count=$(echo "$OPENCODE_RESP" | jq -r '(.auth_methods // []) | length')

  #Keep every entry except this provider's own string entry and any prior
  #engine tuple entry carrying this provider id; the register branch then
  #appends the fresh string entry.
  local keep_rest='((type != "string") or (. != $entry))
          and ((type != "array")
              or (.[0] != $fileurl)
              or ((((.[1] // {}) | .provider? // "")) != $pid))'

  if [ "$method_count" -gt 0 ]; then
    mkdir -p "$plugin_dir"
    {
      printf 'import plugin from "%s"\n' "$engine"
      printf 'export default (input: any) => plugin(input, { provider: "%s", gateway: "%s" })\n' \
        "$PROVIDER_ID" "$GATEWAY"
    } > "$wrapper"
    MERGED_CONFIG=$(echo "$MERGED_CONFIG" | jq --arg entry "$wrapper" --arg fileurl "$fileurl" --arg pid "$PROVIDER_ID" "
      .plugin = ((.plugin // [])
        | map(select($keep_rest))
        + [\$entry])")
    echo "Auth plugin registered for ${PROVIDER_ID}: ${wrapper}"
  else
    rm -f "$wrapper"
    MERGED_CONFIG=$(echo "$MERGED_CONFIG" | jq --arg entry "$wrapper" --arg fileurl "$fileurl" --arg pid "$PROVIDER_ID" "
      .plugin = ((.plugin // [])
        | map(select($keep_rest)))")
    echo "No OAuth methods for ${PROVIDER_ID}; no auth plugin entry."
  fi
}
