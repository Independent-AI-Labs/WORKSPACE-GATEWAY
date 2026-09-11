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
# the VM-owned llamafile server instead. There is NO secondary path: if the
# llamafile server or the gateway stack is not reachable, the test SKIPS
# (clean exit 0) rather than substituting historical data.
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

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
    _SELF="$SHG_SCRIPT_PATH"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    if ! source "$REPO_ROOT/.env"; then echo "[INFO] failed to source $REPO_ROOT/.env" >&2; fi
    set +a
fi

source "$SCRIPT_DIR/lib_event_align.sh" || exit 1

pass=0
fail=0

BOUNDARY_RC=0
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
MODELS_JSON_RC=0
MODELS_JSON=$(curl -fsS --max-time 10 "$GATEWAY_URL/llamafile/v1/models" ) || { MODELS_JSON_RC=$?; MODELS_JSON=""; }
MODEL_ID=""
if [ -n "$MODELS_JSON" ]; then
    MODEL_ID_RC=0
    MODEL_ID=$(printf '%s' "$MODELS_JSON" | jq -r '.data[0].id // empty' ) || { MODEL_ID_RC=$?; MODEL_ID=""; }
fi
assert_eq "llamafile /v1/models returned a model id" "yes" "$(if [ -n "$MODEL_ID" ]; then printf 'yes'; else printf 'no'; fi)"
if [ -z "$MODEL_ID" ]; then
    echo ""
    echo "event_id alignment tests: $pass passed, $fail failed"
    exit 1
fi
echo "[INFO] using model id: $MODEL_ID"

# Send one NON-STREAMING chat request and capture the X-Request-Id header.
RESP_HEADERS=$(mktemp)
RESP_BODY_RC=0
RESP_BODY=$(mktemp)
HTTP_CODE_RC=0
HTTP_CODE=$(curl -sS -D "$RESP_HEADERS" -o "$RESP_BODY" -w "%{http_code}" --max-time 120 \
    -X POST "$GATEWAY_URL/llamafile/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$MODEL_ID\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word: ok\"}],\"stream\":false}" \
    ) || { HTTP_CODE_RC=$?; HTTP_CODE="000"; }
LIVE_RID_RC=0
LIVE_RID=$(grep -i '^x-request-id:' "$RESP_HEADERS" | sed 's/^[Xx]-[Rr]equest-[Ii]d:[[:space:]]*//; s/\r$//' ) || { LIVE_RID_RC=$?; LIVE_RID=""; }
rm -f "$RESP_HEADERS"

echo "[INFO] chat HTTP $HTTP_CODE X-Request-Id=$LIVE_RID"
assert_eq "chat request returned 200" "200" "$HTTP_CODE"
assert_eq "response carries X-Request-Id header" "yes" "$(if [ -n "$LIVE_RID" ]; then printf 'yes'; else printf 'no'; fi)"

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
HAS_CHOICES_RC=0
HAS_CHOICES=$(jq -r 'if ((.choices | length) > 0) then "yes" else "no" end' "$RESP_BODY" ) || { HAS_CHOICES_RC=$?; HAS_CHOICES="no"; }
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
assert_eq "usage_log row appears for this run's request_id" "$LIVE_RID" "$(if [ -n "$U_RID" ]; then printf '%s' "$U_RID"; else printf '(none)'; fi)"

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
assert_eq "request_log row appears for this run's request_id" "$LIVE_RID" "$(if [ -n "$R_RID" ]; then printf '%s' "$R_RID"; else printf '(none)'; fi)"

# Core alignment assertions (request_id populated + event_id match + seconds).
assert_alignment "$U_EID" "$U_RID" "$R_EID" "$R_RID"

echo ""
echo "event_id alignment tests: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi
