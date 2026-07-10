#!/bin/bash
set -euo pipefail

# tests/integration/test_event_id_alignment.sh
#
# Integration test: verifies event_id alignment between usage_log (written by
# the Lua sse-usage plugin) and request_log (written by Vector) for ONE live
# request flowing through the gateway.
#
# This test uses the LOCAL llamafile upstream exclusively. The opencode routes
# cannot produce a usage_log row (upstream account has zero credits -> every
# request returns 401 CreditsError), so we exercise a real 200 response from
# the VM-owned llamafile server instead. There is NO fallback path: if the
# llamafile server or the gateway stack is not reachable, the test SKIPS
# (clean exit 0) rather than degrade onto historical data.
#
# Strategy:
#   1. Record a pre-request boundary timestamp.
#   2. Send one NON-STREAMING chat request through /llamafile/v1/chat/completions
#      and capture the X-Request-Id response header (set by request-id plugin).
#   3. Poll ClickHouse usage_log until the row with THAT request_id appears
#      (sse-usage async write via ngx.timer.at).
#   4. Poll ClickHouse request_log until the row with THAT request_id appears
#      (Vector async write).
#   5. Assert both rows for that one request share the same event_id AND the
#      same request_id (request_id is the join key; event_id equality is the
#      goal of the fix).

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

# Skip (do NOT fail) if either endpoint is unreachable.
if ! setup_endpoints; then
    echo ""
    echo "event_id alignment tests: skipped (endpoint unreachable)"
    exit 0
fi

# Skip (do NOT fail) if the llamafile upstream is not reachable through the
# gateway. We require a real 200 response to produce a usage_log row; without
# the local LLM there is nothing meaningful to assert.
if ! llamafile_reachable; then
    echo "[SKIP] relay-llamafile upstream not reachable at $GATEWAY_URL/llamafile/v1/models"
    echo "       (start it: make install-llamafile MODEL=minicpm5-1b on the VM)"
    echo ""
    echo "event_id alignment tests: skipped (llamafile not running)"
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
    echo "event_id alignment tests: $pass passed, $fail failed"
    exit 1
fi
echo "[INFO] using model id: $MODEL_ID"

# Send one NON-STREAMING chat request and capture the X-Request-Id header.
RESP_HEADERS=$(mktemp)
RESP_BODY=$(mktemp)
HTTP_CODE=$(curl -s -D "$RESP_HEADERS" -o "$RESP_BODY" -w "%{http_code}" --max-time 120 \
    -X POST "$GATEWAY_URL/llamafile/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$MODEL_ID\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word: ok\"}],\"stream\":false}" \
    2>/dev/null || echo "000")
LIVE_RID=$(grep -i '^x-request-id:' "$RESP_HEADERS" | sed 's/^[Xx]-[Rr]equest-[Ii]d:[[:space:]]*//; s/\r$//' || true)
rm -f "$RESP_HEADERS"

echo "[INFO] chat HTTP $HTTP_CODE X-Request-Id=$LIVE_RID"
assert_eq "chat request returned 200" "200" "$HTTP_CODE"
assert_eq "response carries X-Request-Id header" "yes" "$([ -n "$LIVE_RID" ] && echo yes || echo no)"

if [ "$HTTP_CODE" != "200" ] || [ -z "$LIVE_RID" ]; then
    rm -f "$RESP_BODY"
    echo ""
    echo "event_id alignment tests: $pass passed, $fail failed"
    [ "$fail" -gt 0 ] && exit 1
    exit 0
fi

# Verify the upstream returned valid JSON with a choices array. The local
# llamafile server frequently returns usage = 0 in its response body - the
# sse-usage plugin estimates tokens in that case, so token counts are
# asserted from usage_log downstream, NOT from the raw HTTP response.
HAS_CHOICES=$(python3 -c "import sys,json
try:
    d=json.load(sys.stdin)
    print('yes' if d.get('choices') else 'no')
except Exception:
    print('no')" < "$RESP_BODY" 2>/dev/null || echo "no")
rm -f "$RESP_BODY"
assert_eq "llamafile response body has a choices array" "yes" "$HAS_CHOICES"

# Poll usage_log for the row matching THIS request_id (sse-usage async write).
U_EID=""
U_RID=""
for i in $(seq 1 25); do
    ROW=$(pair_by_rid usage_log "$LIVE_RID")
    if [ -n "$ROW" ]; then
        U_EID=$(printf '%s' "$ROW" | cut -f1)
        U_RID=$(printf '%s' "$ROW" | cut -f2)
        break
    fi
    sleep 1
done
assert_eq "usage_log row appears for this run's request_id" "$LIVE_RID" "$([ -n "$U_RID" ] && echo "$U_RID" || echo "(none)")"

# Poll request_log for the row matching THIS request_id (Vector async write).
R_EID=""
R_RID=""
for i in $(seq 1 25); do
    ROW=$(pair_by_rid request_log "$LIVE_RID")
    if [ -n "$ROW" ]; then
        R_EID=$(printf '%s' "$ROW" | cut -f1)
        R_RID=$(printf '%s' "$ROW" | cut -f2)
        break
    fi
    sleep 1
done
assert_eq "request_log row appears for this run's request_id" "$LIVE_RID" "$([ -n "$R_RID" ] && echo "$R_RID" || echo "(none)")"

# Core alignment assertions (request_id populated + event_id match + seconds).
assert_alignment "$U_EID" "$U_RID" "$R_EID" "$R_RID"

echo ""
echo "event_id alignment tests: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi