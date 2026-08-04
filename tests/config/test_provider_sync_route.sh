#!/bin/bash
# Provider-sync route assertions sourced by test_apisix_yaml.sh.

PROVIDER_SYNC_ROUTE=$(echo "$JSON_DATA" | jq -c '[.routes[] | select(.id == "gateway-provider-sync")][0]')
PROVIDER_SYNC_ID=$(echo "$PROVIDER_SYNC_ROUTE" | jq -r '.id')
assert_eq "gateway-provider-sync: id is gateway-provider-sync" "gateway-provider-sync" "$PROVIDER_SYNC_ID"
PROVIDER_SYNC_URI=$(echo "$PROVIDER_SYNC_ROUTE" | jq -r '.uri')
assert_eq "gateway-provider-sync: uri is /gateway/providers*" "/gateway/providers*" "$PROVIDER_SYNC_URI"
PROVIDER_SYNC_HAS_PLUGIN=$(echo "$PROVIDER_SYNC_ROUTE" | jq '.plugins | has("provider-sync")')
assert_eq "gateway-provider-sync: provider-sync plugin present" "true" "$PROVIDER_SYNC_HAS_PLUGIN"
PROVIDER_SYNC_LIMIT_COUNT=$(echo "$PROVIDER_SYNC_ROUTE" | jq '.plugins["limit-count"].count')
assert_eq "gateway-provider-sync: limit-count count is 60" "60" "$PROVIDER_SYNC_LIMIT_COUNT"
PROVIDER_SYNC_LIMIT_WINDOW=$(echo "$PROVIDER_SYNC_ROUTE" | jq '.plugins["limit-count"].time_window')
assert_eq "gateway-provider-sync: limit-count time_window is 60" "60" "$PROVIDER_SYNC_LIMIT_WINDOW"
PROVIDER_SYNC_LIMIT_KEY=$(echo "$PROVIDER_SYNC_ROUTE" | jq -r '.plugins["limit-count"].key')
assert_eq "gateway-provider-sync: limit-count key is remote_addr" "remote_addr" "$PROVIDER_SYNC_LIMIT_KEY"
