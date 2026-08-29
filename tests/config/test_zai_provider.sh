#!/bin/bash
# Z.ai provider assertions sourced by test_apisix_yaml.sh.

# --- relay-zai-key (Z.ai GLM Coding Plan own-key passthrough) ---
ZAI_KEY_ROUTE=$(echo "$JSON_DATA" | jq -c '[.routes[] | select(.id == "relay-zai-key")][0]')

ZAI_KEY_ID=$(echo "$ZAI_KEY_ROUTE" | jq -r '.id')
assert_eq "relay-zai-key: id is relay-zai-key" "relay-zai-key" "$ZAI_KEY_ID"

ZAI_KEY_URI=$(echo "$ZAI_KEY_ROUTE" | jq -r '.uri')
assert_eq "relay-zai-key: uri is /zai-key/*" "/zai-key/*" "$ZAI_KEY_URI"

ZAI_KEY_NODE=$(echo "$ZAI_KEY_ROUTE" | jq -r '.upstream.nodes | keys[0]')
assert_eq "relay-zai-key: upstream node is api.z.ai:443" "api.z.ai:443" "$ZAI_KEY_NODE"

ZAI_KEY_HAS_KEY_RESOLVER=$(echo "$ZAI_KEY_ROUTE" | jq '.plugins | has("key-resolver")')
assert_eq "relay-zai-key: no key-resolver plugin (passthrough)" "false" "$ZAI_KEY_HAS_KEY_RESOLVER"

ZAI_KEY_REWRITE_REGEX=$(echo "$ZAI_KEY_ROUTE" | jq -r '.plugins["proxy-rewrite"].regex_uri[0]')
assert_eq "relay-zai-key: proxy-rewrite regex strips /zai-key/" "^/zai-key/(.*)" "$ZAI_KEY_REWRITE_REGEX"

ZAI_KEY_REWRITE_REPLACE=$(echo "$ZAI_KEY_ROUTE" | jq -r '.plugins["proxy-rewrite"].regex_uri[1]')
assert_eq "relay-zai-key: proxy-rewrite replacement is /api/coding/paas/v4/" '/api/coding/paas/v4/$1' "$ZAI_KEY_REWRITE_REPLACE"

# --- relay-zai-key-v1 (OpenAI-SDK-style /zai-key/v1/* paths) ---
ZAI_KEY_V1_ROUTE=$(echo "$JSON_DATA" | jq -c '[.routes[] | select(.id == "relay-zai-key-v1")][0]')

ZAI_KEY_V1_ID=$(echo "$ZAI_KEY_V1_ROUTE" | jq -r '.id')
assert_eq "relay-zai-key-v1: id is relay-zai-key-v1" "relay-zai-key-v1" "$ZAI_KEY_V1_ID"

ZAI_KEY_V1_URI=$(echo "$ZAI_KEY_V1_ROUTE" | jq -r '.uri')
assert_eq "relay-zai-key-v1: uri is /zai-key/v1/*" "/zai-key/v1/*" "$ZAI_KEY_V1_URI"

ZAI_KEY_V1_NODE=$(echo "$ZAI_KEY_V1_ROUTE" | jq -r '.upstream.nodes | keys[0]')
assert_eq "relay-zai-key-v1: upstream node is api.z.ai:443" "api.z.ai:443" "$ZAI_KEY_V1_NODE"

ZAI_KEY_V1_HAS_KEY_RESOLVER=$(echo "$ZAI_KEY_V1_ROUTE" | jq '.plugins | has("key-resolver")')
assert_eq "relay-zai-key-v1: no key-resolver plugin (passthrough)" "false" "$ZAI_KEY_V1_HAS_KEY_RESOLVER"

ZAI_KEY_V1_REWRITE_REGEX=$(echo "$ZAI_KEY_V1_ROUTE" | jq -r '.plugins["proxy-rewrite"].regex_uri[0]')
assert_eq "relay-zai-key-v1: proxy-rewrite regex strips /zai-key/v1/" "^/zai-key/v1/(.*)" "$ZAI_KEY_V1_REWRITE_REGEX"

ZAI_KEY_V1_REWRITE_REPLACE=$(echo "$ZAI_KEY_V1_ROUTE" | jq -r '.plugins["proxy-rewrite"].regex_uri[1]')
assert_eq "relay-zai-key-v1: proxy-rewrite replacement is /api/coding/paas/v4/" '/api/coding/paas/v4/$1' "$ZAI_KEY_V1_REWRITE_REPLACE"

# --- provider YAML contract: top-level route/npm or /opencode block 500s ---
for pf in "$REPO_ROOT"/conf/providers/*.yaml; do
    pname=$(basename "$pf")
    prow=$(yaml_to_json "$pf" | jq -r '.route // empty')
    assert_eq "$pname: top-level route present (provider-sync.lua:86 nil-guard)" "yes" "$([ -n "$prow" ] && echo yes || echo no)"
    pnpm=$(yaml_to_json "$pf" | jq -r '.npm // empty')
    assert_eq "$pname: top-level npm present" "yes" "$([ -n "$pnpm" ] && echo yes || echo no)"
done
