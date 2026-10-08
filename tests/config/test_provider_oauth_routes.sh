#!/bin/bash
# Generic provider-oauth plugin config assertions sourced by test_apisix_yaml.sh.

# --- relay-kimi: provider-oauth bound with the Kimi config set ---
KIMI_OA_BASE=$(echo "$JSON_DATA" | jq -r '[.routes[] | select(.id == "relay-kimi")][0].plugins["provider-oauth"].auth_base')
assert_eq "relay-kimi: provider-oauth auth_base is /kimi/auth" "/kimi/auth" "$KIMI_OA_BASE"

KIMI_OA_CLIENT=$(echo "$JSON_DATA" | jq -r '[.routes[] | select(.id == "relay-kimi")][0].plugins["provider-oauth"].client_id')
assert_eq "relay-kimi: provider-oauth client_id is the Kimi CLI id" "17e5f671-d194-4dfb-9706-5516cb48c098" "$KIMI_OA_CLIENT"

KIMI_OA_PROTOCOL=$(echo "$JSON_DATA" | jq -r '[.routes[] | select(.id == "relay-kimi")][0].plugins["provider-oauth"].protocol // "rfc8628"')
assert_eq "relay-kimi: provider-oauth protocol is rfc8628" "rfc8628" "$KIMI_OA_PROTOCOL"

KIMI_OA_REJECT=$(echo "$JSON_DATA" | jq -r '[.routes[] | select(.id == "relay-kimi")][0].plugins["provider-oauth"].reject_key_prefix')
assert_eq "relay-kimi: provider-oauth rejects sk- keys" "sk-" "$KIMI_OA_REJECT"

KIMI_OA_PREFIX=$(echo "$JSON_DATA" | jq -r '[.routes[] | select(.id == "relay-kimi")][0].plugins["provider-oauth"].token_prefix')
assert_eq "relay-kimi: provider-oauth token_prefix preserves kimi sessions" "secret/data/gateway/kimi-tokens/" "$KIMI_OA_PREFIX"

KIMI_V1_OA_BASE=$(echo "$JSON_DATA" | jq -r '[.routes[] | select(.id == "relay-kimi-v1")][0].plugins["provider-oauth"].auth_base')
assert_eq "relay-kimi-v1: provider-oauth auth_base is /kimi/auth" "/kimi/auth" "$KIMI_V1_OA_BASE"

# --- relay-openai: provider-oauth bound with the chatgpt_device config set ---
OPENAI_OA=$(echo "$JSON_DATA" | jq -c '[.routes[] | select(.id == "relay-openai")][0].plugins["provider-oauth"]')

OPENAI_OA_PROTOCOL=$(echo "$OPENAI_OA" | jq -r '.protocol')
assert_eq "relay-openai: provider-oauth protocol is chatgpt_device" "chatgpt_device" "$OPENAI_OA_PROTOCOL"

OPENAI_OA_BASE=$(echo "$OPENAI_OA" | jq -r '.auth_base')
assert_eq "relay-openai: provider-oauth auth_base is /openai/auth" "/openai/auth" "$OPENAI_OA_BASE"

OPENAI_OA_BROWSER=$(echo "$OPENAI_OA" | jq -r '.browser_flow')
assert_eq "relay-openai: provider-oauth browser_flow enabled" "true" "$OPENAI_OA_BROWSER"

OPENAI_OA_UA=$(echo "$OPENAI_OA" | jq -r '.user_agent')
assert_eq "relay-openai: provider-oauth pins opencode UA" "opencode/1.18.3" "$OPENAI_OA_UA"

OPENAI_OA_ROTATION=$(echo "$OPENAI_OA" | jq -r '.refresh_rotation_required')
assert_eq "relay-openai: provider-oauth tolerates non-rotating refresh" "false" "$OPENAI_OA_ROTATION"

OPENAI_OA_ACCOUNT_HEADER=$(echo "$OPENAI_OA" | jq -r '.account_header')
assert_eq "relay-openai: provider-oauth maps account claim to header" "ChatGPT-Account-Id" "$OPENAI_OA_ACCOUNT_HEADER"

OPENAI_OA_USERCODE=$(echo "$OPENAI_OA" | jq -r '.device_authorize_path')
assert_eq "relay-openai: provider-oauth device usercode path" "/api/accounts/deviceauth/usercode" "$OPENAI_OA_USERCODE"

# --- provider YAML contract: OAuth providers name the generic plugin ---
KIMI_YAML_PLUGIN=$(yaml_to_json "$REPO_ROOT/conf/providers/workspace-gw-kimi-device-oauth.yaml" | jq -r '.auth.plugin // empty')
assert_eq "kimi provider YAML binds provider-oauth" "provider-oauth" "$KIMI_YAML_PLUGIN"

OPENAI_YAML_PLUGIN=$(yaml_to_json "$REPO_ROOT/conf/providers/workspace-gw-openai-device-oauth.yaml" | jq -r '.auth.plugin // empty')
assert_eq "openai provider YAML binds provider-oauth" "provider-oauth" "$OPENAI_YAML_PLUGIN"

# --- relay-anthropic (bare passthrough, NO auth plugin) ---
ANT_ROUTE=$(echo "$JSON_DATA" | jq -c '[.routes[] | select(.id == "relay-anthropic")][0]')
ANT_URI=$(echo "$ANT_ROUTE" | jq -r '.uri')
assert_eq "relay-anthropic: uri is /anthropic/*" "/anthropic/*" "$ANT_URI"
ANT_NODE=$(echo "$ANT_ROUTE" | jq -r '.upstream.nodes | keys[]')
assert_eq "relay-anthropic: upstream node is api.anthropic.com:443" "api.anthropic.com:443" "$ANT_NODE"
ANT_HAS_OA=$(echo "$ANT_ROUTE" | jq 'has("plugins") and (.plugins | has("provider-oauth"))')
assert_eq "relay-anthropic: NO provider-oauth (client credentials pass through)" "false" "$ANT_HAS_OA"
ANT_HAS_KR=$(echo "$ANT_ROUTE" | jq '.plugins | has("key-resolver")')
assert_eq "relay-anthropic: NO key-resolver" "false" "$ANT_HAS_KR"
ANT_REWRITE=$(echo "$ANT_ROUTE" | jq -c '.plugins["proxy-rewrite"].regex_uri')
assert_eq "relay-anthropic: rewrite strips /anthropic/ only" '["^/anthropic/(.*)","/$1"]' "$ANT_REWRITE"
ANT_ENCODING=$(echo "$ANT_ROUTE" | jq -r '.plugins["proxy-rewrite"].headers.set["accept-encoding"]')
assert_eq "relay-anthropic: forces identity encoding (SSE must stay parseable)" "identity" "$ANT_ENCODING"
ANT_LIMIT_KEY=$(echo "$ANT_ROUTE" | jq -r '.plugins["limit-count"].key')
assert_eq "relay-anthropic: limit-count key is http_x_key_hash" "http_x_key_hash" "$ANT_LIMIT_KEY"
ANT_HAS_SSE=$(echo "$ANT_ROUTE" | jq '.plugins | has("sse-usage")')
assert_eq "relay-anthropic: sse-usage plugin present" "true" "$ANT_HAS_SSE"

# --- relay-anthropic-coding-plan (bare passthrough twin, NO auth plugin) ---
ANTCP_ROUTE=$(echo "$JSON_DATA" | jq -c '[.routes[] | select(.id == "relay-anthropic-coding-plan")][0]')
ANTCP_URI=$(echo "$ANTCP_ROUTE" | jq -r '.uri')
assert_eq "relay-anthropic-coding-plan: uri is /anthropic-coding-plan/*" "/anthropic-coding-plan/*" "$ANTCP_URI"
ANTCP_NODE=$(echo "$ANTCP_ROUTE" | jq -r '.upstream.nodes | keys[]')
assert_eq "relay-anthropic-coding-plan: upstream node is api.anthropic.com:443" "api.anthropic.com:443" "$ANTCP_NODE"
ANTCP_HAS_OA=$(echo "$ANTCP_ROUTE" | jq 'has("plugins") and (.plugins | has("provider-oauth"))')
assert_eq "relay-anthropic-coding-plan: NO provider-oauth (client credentials pass through)" "false" "$ANTCP_HAS_OA"
ANTCP_HAS_KR=$(echo "$ANTCP_ROUTE" | jq '.plugins | has("key-resolver")')
assert_eq "relay-anthropic-coding-plan: NO key-resolver" "false" "$ANTCP_HAS_KR"
ANTCP_REWRITE=$(echo "$ANTCP_ROUTE" | jq -c '.plugins["proxy-rewrite"].regex_uri')
assert_eq "relay-anthropic-coding-plan: rewrite strips its prefix only" '["^/anthropic-coding-plan/(.*)","/$1"]' "$ANTCP_REWRITE"
ANTCP_ENCODING=$(echo "$ANTCP_ROUTE" | jq -r '.plugins["proxy-rewrite"].headers.set["accept-encoding"]')
assert_eq "relay-anthropic-coding-plan: forces identity encoding" "identity" "$ANTCP_ENCODING"
ANTCP_HAS_SSE=$(echo "$ANTCP_ROUTE" | jq '.plugins | has("sse-usage")')
assert_eq "relay-anthropic-coding-plan: sse-usage plugin present" "true" "$ANTCP_HAS_SSE"

# --- anthropic provider YAMLs follow the naming contract ---
ANT_YAML=$(yaml_to_json "$REPO_ROOT/conf/providers/workspace-gw-anthropic-api-key.yaml")
assert_eq "anthropic api-key YAML id follows contract" "workspace-gw-anthropic-api-key" "$(echo "$ANT_YAML" | jq -r '.id')"
assert_eq "anthropic api-key YAML auth type" "api_key" "$(echo "$ANT_YAML" | jq -r '.auth.type')"
assert_eq "anthropic api-key YAML route" "/anthropic/v1" "$(echo "$ANT_YAML" | jq -r '.route')"
assert_eq "anthropic api-key YAML npm" "@ai-sdk/anthropic" "$(echo "$ANT_YAML" | jq -r '.npm')"

ANTCP_YAML=$(yaml_to_json "$REPO_ROOT/conf/providers/workspace-gw-anthropic-coding-plan-passthrough.yaml")
assert_eq "anthropic coding-plan YAML id follows contract" "workspace-gw-anthropic-coding-plan-passthrough" "$(echo "$ANTCP_YAML" | jq -r '.id')"
assert_eq "anthropic coding-plan YAML name follows contract" "Workspace GW (Anthropic Coding Plan Passthrough)" "$(echo "$ANTCP_YAML" | jq -r '.name')"
assert_eq "anthropic coding-plan YAML auth type" "passthrough" "$(echo "$ANTCP_YAML" | jq -r '.auth.type')"
assert_eq "anthropic coding-plan YAML route" "/anthropic-coding-plan/v1" "$(echo "$ANTCP_YAML" | jq -r '.route')"
assert_eq "anthropic coding-plan YAML npm" "@ai-sdk/anthropic" "$(echo "$ANTCP_YAML" | jq -r '.npm')"
assert_eq "anthropic coding-plan YAML declares one client_oauth method" "1" "$(echo "$ANTCP_YAML" | jq '.auth.methods | length')"
assert_eq "anthropic coding-plan client flow" "client_oauth" "$(echo "$ANTCP_YAML" | jq -r '.auth.methods[0].flow')"
assert_eq "anthropic coding-plan client method is route-less (client-side only)" "none" "$(echo "$ANTCP_YAML" | jq -r '.auth.methods[0].route // "none"')"

# --- ROUTE_PROVIDERS drift guard: every non-oauth provider route family is
# --- mapped in cost_calc.lua for cost attribution (zai regression class) ---
SSE_USAGE="$REPO_ROOT/plugins/custom/cost_calc.lua"
for pf in "$REPO_ROOT"/conf/providers/*.yaml; do
    pjson=$(yaml_to_json "$pf")
    pid=$(echo "$pjson" | jq -r '.id // empty')
    pauth=$(echo "$pjson" | jq -r '.auth.type // "none"')
    if [ -n "$pid" ] && [ "$pauth" != "oauth" ]; then
        if grep -q "\"$pid\"" "$SSE_USAGE"; then
            assert_eq "$pid mapped in route-provider map" "yes" "yes"
        else
            assert_eq "$pid mapped in route-provider map" "yes" "no"
        fi
    fi
done
