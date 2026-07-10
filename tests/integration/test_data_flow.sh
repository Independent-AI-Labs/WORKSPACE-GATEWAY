#!/bin/bash
set -euo pipefail

# tests/integration/test_data_flow.sh
#
# End-to-end data-flow test through the LOCAL llamafile upstream (VM-owned
# server). Sends one non-streaming chat request via /llamafile/*, then asserts
# both request_log (Vector) and usage_log (Lua sse-usage) carry the row for
# THAT request's request_id with the expected fields populated.
#
# Uses the llamafile route exclusively. There is NO fallback path. If the
# llamafile server or the gateway stack is not reachable, the test SKIPS
# (clean exit 0) rather than degrade onto historical / opencode-route data.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    source "$REPO_ROOT/.env" || true
    set +a
fi

source "$SCRIPT_DIR/lib_event_align.sh"

pass=0
fail=0

BOUNDARY=$(date +%s)
echo "[INFO] boundary=$BOUNDARY"

if ! setup_endpoints; then
    echo ""
    echo "data flow tests: skipped (endpoint unreachable)"
    exit 0
fi

if ! llamafile_reachable; then
    echo "[SKIP] relay-llamafile upstream not reachable at $GATEWAY_URL/llamafile/v1/models"
    echo "       (start it: make install-llamafile MODEL=minicpm5-1b on the VM)"
    echo ""
    echo "data flow tests: skipped (llamafile not running)"
    exit 0
fi

# Resolve the model id from /llamafile/v1/models.
MODELS_JSON=$(curl -sf --max-time 10 "$GATEWAY_URL/llamafile/v1/models" 2>/dev/null || echo "")
MODEL_ID=""
if [ -n "$MODELS_JSON" ]; then
    MODEL_ID=$(printf '%s' "$MODELS_JSON" | python3 -c "import sys,json
try:
    d=json.load(sys.stdin)
    print(d['data'][0]['id'] if d.get('data') else '')
except Exception:
    print('')" 2>/dev/null || echo "")
fi
assert_eq "llamafile /v1/models returned a model id" "yes" "$([ -n "$MODEL_ID" ] && echo yes || echo no)"
if [ -z "$MODEL_ID" ]; then
    echo ""
    echo "data flow tests: $pass passed, $fail failed"
    exit 1
fi
echo "[INFO] using model id: $MODEL_ID"

# Send one non-streaming chat request; capture X-Request-Id.
RESP_HEADERS=$(mktemp)
RESP_BODY=$(mktemp)
HTTP_CODE=$(curl -s -D "$RESP_HEADERS" -o "$RESP_BODY" -w "%{http_code}" --max-time 120 \
    -X POST "$GATEWAY_URL/llamafile/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$MODEL_ID\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in one word\"}],\"stream\":false}" \
    2>/dev/null || echo "000")
LIVE_RID=$(grep -i '^x-request-id:' "$RESP_HEADERS" | sed 's/^[Xx]-[Rr]equest-[Ii]d:[[:space:]]*//; s/\r$//' || true)
rm -f "$RESP_HEADERS"

echo "[INFO] chat HTTP $HTTP_CODE X-Request-Id=$LIVE_RID"
assert_eq "chat request through gateway returned 200" "200" "$HTTP_CODE"
assert_eq "response carries X-Request-Id header" "yes" "$([ -n "$LIVE_RID" ] && echo yes || echo no)"

if [ "$HTTP_CODE" != "200" ] || [ -z "$LIVE_RID" ]; then
    rm -f "$RESP_BODY"
    echo ""
    echo "data flow tests: $pass passed, $fail failed"
    [ "$fail" -gt 0 ] && exit 1
    exit 0
fi

# Pull extended request_log columns for THIS request_id (Vector write).
RLOG=""
for i in $(seq 1 25); do
    RLOG=$(ch_query "SELECT request_id, model, status, client_ip, request_size, req_body, upstream_response_time_s FROM llm_gateway.request_log WHERE request_id = '$LIVE_RID' LIMIT 1")
    [ -n "$RLOG" ] && break
    sleep 1
done
if [ -n "$RLOG" ]; then
    R_RID=$(printf '%s' "$RLOG" | cut -f1)
    R_MODEL=$(printf '%s' "$RLOG" | cut -f2)
    R_STATUS=$(printf '%s' "$RLOG" | cut -f3)
    R_CLIENT_IP=$(printf '%s' "$RLOG" | cut -f4)
    R_REQ_SIZE=$(printf '%s' "$RLOG" | cut -f5)
    R_REQ_BODY=$(printf '%s' "$RLOG" | cut -f6)
    R_UPSTREAM_S=$(printf '%s' "$RLOG" | cut -f7)
    echo "[INFO] request_log row: model=$R_MODEL status=$R_STATUS client_ip=$R_CLIENT_IP req_size=$R_REQ_SIZE upstream=${R_UPSTREAM_S}s"
    assert_eq "request_log row appears for this run's request_id" "$LIVE_RID" "$R_RID"
    assert_eq "request_log.model is populated" "yes" "$([ -n "$R_MODEL" ] && echo yes || echo no)"
    assert_eq "request_log.status == 200" "200" "$R_STATUS"
    assert_eq "request_log.client_ip populated (default log restored)" "true" "$([ "$R_CLIENT_IP" != "0.0.0.0" ] && [ -n "$R_CLIENT_IP" ] && echo true || echo false)"
    assert_eq "request_log.request_size > 0" "true" "$([ "${R_REQ_SIZE:-0}" -gt 0 ] && echo true || echo false)"
    assert_eq "request_log.req_body populated" "yes" "$([ -n "$R_REQ_BODY" ] && [ "$R_REQ_BODY" != "" ] && echo yes || echo no)"
else
    assert_eq "request_log row appears for this run's request_id" "$LIVE_RID" "(none)"
fi

# Pull usage_log columns for THIS request_id (Lua sse-usage write).
ULOG=""
for i in $(seq 1 25); do
    ULOG=$(ch_query "SELECT request_id, model, prompt_tokens, completion_tokens, total_tokens FROM llm_gateway.usage_log WHERE request_id = '$LIVE_RID' LIMIT 1")
    [ -n "$ULOG" ] && break
    sleep 1
done
if [ -n "$ULOG" ]; then
    U_RID=$(printf '%s' "$ULOG" | cut -f1)
    U_MODEL=$(printf '%s' "$ULOG" | cut -f2)
    U_PROMPT=$(printf '%s' "$ULOG" | cut -f3)
    U_COMPLETION=$(printf '%s' "$ULOG" | cut -f4)
    U_TOTAL=$(printf '%s' "$ULOG" | cut -f5)
    echo "[INFO] usage_log row: model=$U_MODEL prompt=$U_PROMPT completion=$U_COMPLETION total=$U_TOTAL"
    assert_eq "usage_log row appears for this run's request_id" "$LIVE_RID" "$U_RID"
    assert_eq "usage_log.model normalized == normalize_key(model id)" "$(printf '%s' "$MODEL_ID" | sed 's|.*/||' | tr 'A-Z' 'a-z')" "$U_MODEL"
    assert_eq "usage_log.prompt_tokens > 0" "true" "$([ "${U_PROMPT:-0}" -gt 0 ] && echo true || echo false)"
    assert_eq "usage_log.completion_tokens > 0" "true" "$([ "${U_COMPLETION:-0}" -gt 0 ] && echo true || echo false)"
    assert_eq "usage_log.total_tokens > 0" "true" "$([ "${U_TOTAL:-0}" -gt 0 ] && echo true || echo false)"
else
    assert_eq "usage_log row appears for this run's request_id" "$LIVE_RID" "(none)"
fi

rm -f "$RESP_BODY"

echo ""
echo "data flow tests: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi