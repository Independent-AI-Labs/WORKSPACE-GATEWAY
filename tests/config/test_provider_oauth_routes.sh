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

# --- relay-anthropic-device (custodial device facade, anthropic engine) ---
ANTD_OA=$(echo "$JSON_DATA" | jq -c '[.routes[] | select(.id == "relay-anthropic-device")][0].plugins["provider-oauth"]')
ANTD_URI=$(echo "$JSON_DATA" | jq -r '[.routes[] | select(.id == "relay-anthropic-device")][0].uri')
assert_eq "relay-anthropic-device: uri is /anthropic-device/*" "/anthropic-device/*" "$ANTD_URI"
ANTD_PROTOCOL=$(echo "$ANTD_OA" | jq -r '.protocol')
assert_eq "relay-anthropic-device: protocol is anthropic" "anthropic" "$ANTD_PROTOCOL"
ANTD_BASE=$(echo "$ANTD_OA" | jq -r '.auth_base')
assert_eq "relay-anthropic-device: auth_base is /anthropic-device/auth" "/anthropic-device/auth" "$ANTD_BASE"
ANTD_CLIENT=$(echo "$ANTD_OA" | jq -r '.client_id')
assert_eq "relay-anthropic-device: client_id is the Claude Code public client" "9d1c250a-e61b-44d9-88ed-5944d1962f5e" "$ANTD_CLIENT"
ANTD_AUTH_HOST=$(echo "$ANTD_OA" | jq -r '.oauth_host')
assert_eq "relay-anthropic-device: authorize host is claude.ai" "https://claude.ai" "$ANTD_AUTH_HOST"
ANTD_TOKEN_HOST=$(echo "$ANTD_OA" | jq -r '.token_host')
assert_eq "relay-anthropic-device: token host is platform.claude.com" "https://platform.claude.com" "$ANTD_TOKEN_HOST"
ANTD_TOKEN_PATH=$(echo "$ANTD_OA" | jq -r '.token_path')
assert_eq "relay-anthropic-device: token path is /v1/oauth/token" "/v1/oauth/token" "$ANTD_TOKEN_PATH"
ANTD_REDIRECT=$(echo "$ANTD_OA" | jq -r '.browser_redirect_uri')
assert_eq "relay-anthropic-device: redirect is the manual CODE#STATE callback" "https://platform.claude.com/oauth/code/callback" "$ANTD_REDIRECT"
ANTD_CODE_PARAM=$(echo "$ANTD_OA" | jq -r '.authorize_params.code')
assert_eq "relay-anthropic-device: authorize carries code=true" "true" "$ANTD_CODE_PARAM"
ANTD_VERIFY_PAGE=$(echo "$ANTD_OA" | jq -r '.verify_page')
assert_eq "relay-anthropic-device: verify page enabled" "true" "$ANTD_VERIFY_PAGE"
ANTD_ORIGIN=$(echo "$ANTD_OA" | jq -r '.verification_origin')
assert_eq "relay-anthropic-device: verification origin is the public gateway" "https://gw.workspaceguardrails.com" "$ANTD_ORIGIN"
ANTD_TOKEN_PREFIX=$(echo "$ANTD_OA" | jq -r '.token_prefix')
assert_eq "relay-anthropic-device: token_prefix preserves anthropic sessions" "secret/data/gateway/anthropic-tokens/" "$ANTD_TOKEN_PREFIX"
ANTD_DEVICE_PREFIX=$(echo "$ANTD_OA" | jq -r '.device_prefix')
assert_eq "relay-anthropic-device: device_prefix for facade records" "secret/data/gateway/anthropic-device/" "$ANTD_DEVICE_PREFIX"
ANTD_REJECT=$(echo "$ANTD_OA" | jq -r '.reject_key_prefix')
assert_eq "relay-anthropic-device: rejects sk-ant- keys" "sk-ant-" "$ANTD_REJECT"
ANTD_POINTER=$(echo "$ANTD_OA" | jq -r '.reject_key_pointer')
assert_eq "relay-anthropic-device: rejection pointer is /anthropic" "/anthropic" "$ANTD_POINTER"
ANTD_BETA_Q=$(echo "$ANTD_OA" | jq -r '.beta_query_path')
assert_eq "relay-anthropic-device: beta query path is /v1/messages" "/v1/messages" "$ANTD_BETA_Q"
ANTD_BETA_H=$(echo "$ANTD_OA" | jq -r '.fixed_upstream_headers["anthropic-beta"]')
assert_eq "relay-anthropic-device: oauth beta header injected upstream" "oauth-2025-04-20" "$ANTD_BETA_H"
ANTD_ENCODING=$(echo "$JSON_DATA" | jq -r '[.routes[] | select(.id == "relay-anthropic-device")][0].plugins["proxy-rewrite"].headers.set["accept-encoding"]')
assert_eq "relay-anthropic-device: forces identity encoding (SSE must stay parseable)" "identity" "$ANTD_ENCODING"
ANTD_ROTATION=$(echo "$ANTD_OA" | jq -r '.refresh_rotation_required')
assert_eq "relay-anthropic-device: tolerates non-rotating refresh" "false" "$ANTD_ROTATION"
ANTD_LIMIT_KEY=$(echo "$JSON_DATA" | jq -r '[.routes[] | select(.id == "relay-anthropic-device")][0].plugins["limit-count"].key')
assert_eq "relay-anthropic-device: limit-count key is http_x_gateway_key_id" "http_x_gateway_key_id" "$ANTD_LIMIT_KEY"

# --- anthropic provider YAMLs follow the naming contract ---
ANT_YAML=$(yaml_to_json "$REPO_ROOT/conf/providers/workspace-gw-anthropic-passthrough.yaml")
assert_eq "anthropic passthrough YAML id follows contract" "workspace-gw-anthropic-passthrough" "$(echo "$ANT_YAML" | jq -r '.id')"
assert_eq "anthropic passthrough YAML auth type" "passthrough" "$(echo "$ANT_YAML" | jq -r '.auth.type')"
assert_eq "anthropic passthrough YAML route" "/anthropic" "$(echo "$ANT_YAML" | jq -r '.route')"
assert_eq "anthropic passthrough YAML npm" "@anthropic-ai/sdk" "$(echo "$ANT_YAML" | jq -r '.npm')"
ANTD_YAML=$(yaml_to_json "$REPO_ROOT/conf/providers/workspace-gw-anthropic-device-oauth.yaml")
assert_eq "anthropic device YAML id follows contract" "workspace-gw-anthropic-device-oauth" "$(echo "$ANTD_YAML" | jq -r '.id')"
assert_eq "anthropic device YAML auth type" "oauth" "$(echo "$ANTD_YAML" | jq -r '.auth.type')"
assert_eq "anthropic device YAML binds provider-oauth" "provider-oauth" "$(echo "$ANTD_YAML" | jq -r '.auth.plugin // empty')"
assert_eq "anthropic device YAML method flow" "device_authorization" "$(echo "$ANTD_YAML" | jq -r '.auth.methods[0].flow')"
assert_eq "anthropic device YAML method route" "/anthropic-device/auth" "$(echo "$ANTD_YAML" | jq -r '.auth.methods[0].route')"
assert_eq "anthropic device YAML route" "/anthropic-device" "$(echo "$ANTD_YAML" | jq -r '.route')"

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
