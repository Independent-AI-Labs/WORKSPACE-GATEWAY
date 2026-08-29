#!/bin/bash
# Generic oauth-auth plugin config assertions sourced by test_apisix_yaml.sh.

# --- relay-kimi: oauth-auth bound with the Kimi config set ---
KIMI_OA_BASE=$(echo "$JSON_DATA" | jq -r '[.routes[] | select(.id == "relay-kimi")][0].plugins["oauth-auth"].auth_base')
assert_eq "relay-kimi: oauth-auth auth_base is /kimi/auth" "/kimi/auth" "$KIMI_OA_BASE"

KIMI_OA_CLIENT=$(echo "$JSON_DATA" | jq -r '[.routes[] | select(.id == "relay-kimi")][0].plugins["oauth-auth"].client_id')
assert_eq "relay-kimi: oauth-auth client_id is the Kimi CLI id" "17e5f671-d194-4dfb-9706-5516cb48c098" "$KIMI_OA_CLIENT"

KIMI_OA_PROTOCOL=$(echo "$JSON_DATA" | jq -r '[.routes[] | select(.id == "relay-kimi")][0].plugins["oauth-auth"].protocol // "rfc8628"')
assert_eq "relay-kimi: oauth-auth protocol is rfc8628" "rfc8628" "$KIMI_OA_PROTOCOL"

KIMI_OA_REJECT=$(echo "$JSON_DATA" | jq -r '[.routes[] | select(.id == "relay-kimi")][0].plugins["oauth-auth"].reject_key_prefix')
assert_eq "relay-kimi: oauth-auth rejects sk- keys" "sk-" "$KIMI_OA_REJECT"

KIMI_OA_PREFIX=$(echo "$JSON_DATA" | jq -r '[.routes[] | select(.id == "relay-kimi")][0].plugins["oauth-auth"].token_prefix')
assert_eq "relay-kimi: oauth-auth token_prefix preserves kimi sessions" "secret/data/gateway/kimi-tokens/" "$KIMI_OA_PREFIX"

KIMI_V1_OA_BASE=$(echo "$JSON_DATA" | jq -r '[.routes[] | select(.id == "relay-kimi-v1")][0].plugins["oauth-auth"].auth_base')
assert_eq "relay-kimi-v1: oauth-auth auth_base is /kimi/auth" "/kimi/auth" "$KIMI_V1_OA_BASE"

# --- relay-openai: oauth-auth bound with the chatgpt_device config set ---
OPENAI_OA=$(echo "$JSON_DATA" | jq -c '[.routes[] | select(.id == "relay-openai")][0].plugins["oauth-auth"]')

OPENAI_OA_PROTOCOL=$(echo "$OPENAI_OA" | jq -r '.protocol')
assert_eq "relay-openai: oauth-auth protocol is chatgpt_device" "chatgpt_device" "$OPENAI_OA_PROTOCOL"

OPENAI_OA_BASE=$(echo "$OPENAI_OA" | jq -r '.auth_base')
assert_eq "relay-openai: oauth-auth auth_base is /openai/auth" "/openai/auth" "$OPENAI_OA_BASE"

OPENAI_OA_BROWSER=$(echo "$OPENAI_OA" | jq -r '.browser_flow')
assert_eq "relay-openai: oauth-auth browser_flow enabled" "true" "$OPENAI_OA_BROWSER"

OPENAI_OA_UA=$(echo "$OPENAI_OA" | jq -r '.user_agent')
assert_eq "relay-openai: oauth-auth pins opencode UA" "opencode/1.18.3" "$OPENAI_OA_UA"

OPENAI_OA_ROTATION=$(echo "$OPENAI_OA" | jq -r '.refresh_rotation_required')
assert_eq "relay-openai: oauth-auth tolerates non-rotating refresh" "false" "$OPENAI_OA_ROTATION"

OPENAI_OA_ACCOUNT_HEADER=$(echo "$OPENAI_OA" | jq -r '.account_header')
assert_eq "relay-openai: oauth-auth maps account claim to header" "ChatGPT-Account-Id" "$OPENAI_OA_ACCOUNT_HEADER"

OPENAI_OA_USERCODE=$(echo "$OPENAI_OA" | jq -r '.device_authorize_path')
assert_eq "relay-openai: oauth-auth device usercode path" "/api/accounts/deviceauth/usercode" "$OPENAI_OA_USERCODE"

# --- provider YAML contract: OAuth providers name the generic plugin ---
KIMI_YAML_PLUGIN=$(yaml_to_json "$REPO_ROOT/conf/providers/workspace-gw-kimi-device-oauth.yaml" | jq -r '.auth.plugin // empty')
assert_eq "kimi provider YAML binds oauth-auth" "oauth-auth" "$KIMI_YAML_PLUGIN"

OPENAI_YAML_PLUGIN=$(yaml_to_json "$REPO_ROOT/conf/providers/workspace-gw-openai-device-oauth.yaml" | jq -r '.auth.plugin // empty')
assert_eq "openai provider YAML binds oauth-auth" "oauth-auth" "$OPENAI_YAML_PLUGIN"

# --- ROUTE_PROVIDERS drift guard: every non-oauth provider route family is
# --- mapped in sse-usage.lua for cost attribution (zai regression class) ---
SSE_USAGE="$REPO_ROOT/plugins/custom/sse-usage.lua"
for pf in "$REPO_ROOT"/conf/providers/*.yaml; do
    pjson=$(yaml_to_json "$pf")
    pid=$(echo "$pjson" | jq -r '.id // empty')
    pauth=$(echo "$pjson" | jq -r '.auth.type // "none"')
    if [ -n "$pid" ] && [ "$pauth" != "oauth" ]; then
        if grep -q "\"$pid\"" "$SSE_USAGE"; then
            assert_eq "$pid mapped in sse-usage ROUTE_PROVIDERS" "yes" "yes"
        else
            assert_eq "$pid mapped in sse-usage ROUTE_PROVIDERS" "yes" "no"
        fi
    fi
done
