#!/bin/bash
# Alibaba Cloud Token Plan route + provider assertions sourced by test_apisix_yaml.sh.

# --- relay-alibaba-token-plan (International/Singapore) ---
ATP_ROUTE=$(echo "$JSON_DATA" | jq -c '[.routes[] | select(.id == "relay-alibaba-token-plan")][0]')

ATP_ID=$(echo "$ATP_ROUTE" | jq -r '.id')
assert_eq "relay-alibaba-token-plan: id is relay-alibaba-token-plan" "relay-alibaba-token-plan" "$ATP_ID"

ATP_URI=$(echo "$ATP_ROUTE" | jq -r '.uri')
assert_eq "relay-alibaba-token-plan: uri is /token-plan/*" "/token-plan/*" "$ATP_URI"

ATP_SCHEME=$(echo "$ATP_ROUTE" | jq -r '.upstream.scheme')
assert_eq "relay-alibaba-token-plan: upstream scheme is https" "https" "$ATP_SCHEME"

ATP_NODE=$(echo "$ATP_ROUTE" | jq -r '.upstream.nodes | keys[0]')
assert_eq "relay-alibaba-token-plan: upstream node is token-plan.ap-southeast-1.maas.aliyuncs.com:443" "token-plan.ap-southeast-1.maas.aliyuncs.com:443" "$ATP_NODE"

ATP_PASS_HOST=$(echo "$ATP_ROUTE" | jq -r '.upstream.pass_host')
assert_eq "relay-alibaba-token-plan: pass_host is node" "node" "$ATP_PASS_HOST"

ATP_HAS_KR=$(echo "$ATP_ROUTE" | jq '.plugins | has("key-resolver")')
assert_eq "relay-alibaba-token-plan: no key-resolver (passthrough)" "false" "$ATP_HAS_KR"

ATP_HAS_OA=$(echo "$ATP_ROUTE" | jq '.plugins | has("provider-oauth")')
assert_eq "relay-alibaba-token-plan: no provider-oauth (passthrough)" "false" "$ATP_HAS_OA"

ATP_HAS_KM=$(echo "$ATP_ROUTE" | jq '.plugins | has("key-meta")')
assert_eq "relay-alibaba-token-plan: key-meta present" "true" "$ATP_HAS_KM"

ATP_REWRITE=$(echo "$ATP_ROUTE" | jq -c '.plugins["proxy-rewrite"].regex_uri')
assert_eq "relay-alibaba-token-plan: rewrite strips /token-plan/ only" '["^/token-plan/(.*)","/$1"]' "$ATP_REWRITE"

ATP_ENCODING=$(echo "$ATP_ROUTE" | jq -r '.plugins["proxy-rewrite"].headers.set["accept-encoding"]')
assert_eq "relay-alibaba-token-plan: forces identity encoding" "identity" "$ATP_ENCODING"

ATP_LIMIT_KEY=$(echo "$ATP_ROUTE" | jq -r '.plugins["limit-count"].key')
assert_eq "relay-alibaba-token-plan: limit-count key is http_x_key_hash" "http_x_key_hash" "$ATP_LIMIT_KEY"

ATP_HAS_SSE=$(echo "$ATP_ROUTE" | jq '.plugins | has("sse-usage")')
assert_eq "relay-alibaba-token-plan: sse-usage plugin present" "true" "$ATP_HAS_SSE"

# --- relay-alibaba-token-plan-cn (China/Beijing) ---
ATPC_ROUTE=$(echo "$JSON_DATA" | jq -c '[.routes[] | select(.id == "relay-alibaba-token-plan-cn")][0]')

ATPC_ID=$(echo "$ATPC_ROUTE" | jq -r '.id')
assert_eq "relay-alibaba-token-plan-cn: id is relay-alibaba-token-plan-cn" "relay-alibaba-token-plan-cn" "$ATPC_ID"

ATPC_URI=$(echo "$ATPC_ROUTE" | jq -r '.uri')
assert_eq "relay-alibaba-token-plan-cn: uri is /token-plan-cn/*" "/token-plan-cn/*" "$ATPC_URI"

ATPC_NODE=$(echo "$ATPC_ROUTE" | jq -r '.upstream.nodes | keys[0]')
assert_eq "relay-alibaba-token-plan-cn: upstream node is token-plan.cn-beijing.maas.aliyuncs.com:443" "token-plan.cn-beijing.maas.aliyuncs.com:443" "$ATPC_NODE"

ATPC_HAS_KR=$(echo "$ATPC_ROUTE" | jq '.plugins | has("key-resolver")')
assert_eq "relay-alibaba-token-plan-cn: no key-resolver (passthrough)" "false" "$ATPC_HAS_KR"

ATPC_HAS_OA=$(echo "$ATPC_ROUTE" | jq '.plugins | has("provider-oauth")')
assert_eq "relay-alibaba-token-plan-cn: no provider-oauth (passthrough)" "false" "$ATPC_HAS_OA"

ATPC_REWRITE=$(echo "$ATPC_ROUTE" | jq -c '.plugins["proxy-rewrite"].regex_uri')
assert_eq "relay-alibaba-token-plan-cn: rewrite strips /token-plan-cn/ only" '["^/token-plan-cn/(.*)","/$1"]' "$ATPC_REWRITE"

ATPC_ENCODING=$(echo "$ATPC_ROUTE" | jq -r '.plugins["proxy-rewrite"].headers.set["accept-encoding"]')
assert_eq "relay-alibaba-token-plan-cn: forces identity encoding" "identity" "$ATPC_ENCODING"

# --- provider YAMLs follow the naming + passthrough contract ---
ATP_YAML=$(yaml_to_json "$REPO_ROOT/conf/providers/workspace-gw-alibaba-token-plan-passthrough.yaml")
assert_eq "alibaba token-plan YAML id follows contract" "workspace-gw-alibaba-token-plan-passthrough" "$(echo "$ATP_YAML" | jq -r '.id')"
assert_eq "alibaba token-plan YAML name follows contract" "Workspace GW (Alibaba Cloud Token Plan Passthrough)" "$(echo "$ATP_YAML" | jq -r '.name')"
assert_eq "alibaba token-plan YAML provider.id" "alibaba-token-plan" "$(echo "$ATP_YAML" | jq -r '.provider.id')"
assert_eq "alibaba token-plan YAML label" "Alibaba Cloud Token Plan" "$(echo "$ATP_YAML" | jq -r '.provider.label')"
assert_eq "alibaba token-plan YAML auth type" "passthrough" "$(echo "$ATP_YAML" | jq -r '.auth.type')"
assert_eq "alibaba token-plan YAML route" "/token-plan" "$(echo "$ATP_YAML" | jq -r '.route')"
assert_eq "alibaba token-plan YAML npm" "@anthropic-ai/sdk" "$(echo "$ATP_YAML" | jq -r '.npm')"
assert_eq "alibaba token-plan YAML model_source.provider" "alibaba-token-plan" "$(echo "$ATP_YAML" | jq -r '.model_source.provider')"
assert_eq "alibaba token-plan YAML pricing provider" "alibaba-token-plan" "$(echo "$ATP_YAML" | jq -r '.pricing.source.provider')"

ATPC_YAML=$(yaml_to_json "$REPO_ROOT/conf/providers/workspace-gw-alibaba-token-plan-cn-passthrough.yaml")
assert_eq "alibaba token-plan-cn YAML id follows contract" "workspace-gw-alibaba-token-plan-cn-passthrough" "$(echo "$ATPC_YAML" | jq -r '.id')"
assert_eq "alibaba token-plan-cn YAML name follows contract" "Workspace GW (Alibaba Cloud Token Plan (China) Passthrough)" "$(echo "$ATPC_YAML" | jq -r '.name')"
assert_eq "alibaba token-plan-cn YAML provider.id" "alibaba-token-plan-cn" "$(echo "$ATPC_YAML" | jq -r '.provider.id')"
assert_eq "alibaba token-plan-cn YAML auth type" "passthrough" "$(echo "$ATPC_YAML" | jq -r '.auth.type')"
assert_eq "alibaba token-plan-cn YAML route" "/token-plan-cn" "$(echo "$ATPC_YAML" | jq -r '.route')"
assert_eq "alibaba token-plan-cn YAML model_source.provider" "alibaba-token-plan-cn" "$(echo "$ATPC_YAML" | jq -r '.model_source.provider')"

# --- routes mapped in the single-source route-provider map ---
SSE_USAGE_FILE="$REPO_ROOT/plugins/custom/cost_calc.lua"
for rid in relay-alibaba-token-plan relay-alibaba-token-plan-cn; do
    if grep -q "\"$rid\"" "$SSE_USAGE_FILE"; then
        assert_eq "$rid mapped in route-provider map" "yes" "yes"
    else
        assert_eq "$rid mapped in route-provider map" "yes" "no"
    fi
done
