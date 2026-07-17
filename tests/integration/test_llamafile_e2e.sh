#!/bin/bash
set -euo pipefail

# tests/integration/test_llamafile_e2e.sh
#
# End-to-end happy path through the LOCAL llamafile upstream (VM-owned server,
# routed by the gateway's relay-llamafile route). Unlike the opencode routes
# that always return 401 (zero upstream credits), this exercises a REAL 200
# response with a usage object, so usage_log + request_log rows are written
# and the event_id alignment fix is validated end-to-end on live data.
#
# Requires NO OPENCODE_API_KEY and NO credits: only the local llamafile server
# (make install-llamafile MODEL=minicpm5-1b on the VM) + a running gateway.

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
    echo "llamafile e2e tests: skipped (endpoint unreachable)"
    exit 0
fi

# Skip guard: the relay-llamafile route upstream must be reachable. If the VM
# llamafile server is not running, skip rather than fail (allow CI without a
# local LLM to pass).
if ! llamafile_reachable; then
    echo "[SKIP] relay-llamafile upstream not reachable at $GATEWAY_URL/llamafile/v1/models"
    echo "       (start it: make install-llamafile MODEL=minicpm5-1b on the VM)"
    echo ""
    echo "llamafile e2e tests: skipped (llamafile not running)"
    exit 0
fi

# Parse the first model id from /llamafile/v1/models.
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
    echo "llamafile e2e tests: $pass passed, $fail failed"
    exit 1
fi
echo "[INFO] using model id: $MODEL_ID"

# Send a NON-STREAMING chat request, capturing the X-Request-Id response header.
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
assert_eq "llamafile chat/completions returned 200" "200" "$HTTP_CODE"
assert_eq "llamafile response carries X-Request-Id header" "yes" "$([ -n "$LIVE_RID" ] && echo yes || echo no)"

if [ "$HTTP_CODE" != "200" ] || [ -z "$LIVE_RID" ]; then
    rm -f "$RESP_BODY"
    echo ""
    echo "llamafile e2e tests: $pass passed, $fail failed"
    [ "$fail" -gt 0 ] && exit 1
    exit 0
fi

# Verify the response body is valid JSON with a choices array (proves the
# upstream is a real LLM, not a stub). NOTE: the local llamafile server
# frequently returns usage = 0 in its response body - the sse-usage Lua
# plugin is responsible for estimating tokens in that case. Token-count
# correctness is therefore asserted from usage_log downstream, NOT from the
# raw HTTP response usage object.
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

# Poll request_log for the row matching THIS request_id (Vector write).
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

# Core alignment assertions (request_id + event_id match on both tables).
assert_alignment "$U_EID" "$U_RID" "$R_EID" "$R_RID"

# Additional usage_log assertions: cost_source enum valid, model normalized.
if [ -n "$U_RID" ]; then
    COST_ROW=$(ch_query "SELECT cost_source, model, prompt_tokens, completion_tokens, total_tokens FROM llm_gateway.usage_log WHERE request_id = '$U_RID' LIMIT 1")
    U_COST_SOURCE=$(printf '%s' "$COST_ROW" | cut -f1)
    U_MODEL=$(printf '%s' "$COST_ROW" | cut -f2)
    U_PROMPT=$(printf '%s' "$COST_ROW" | cut -f3)
    U_COMPLETION=$(printf '%s' "$COST_ROW" | cut -f4)
    U_TOTAL=$(printf '%s' "$COST_ROW" | cut -f5)
    echo "[INFO] usage_log row: cost_source=$U_COST_SOURCE model=$U_MODEL tokens=$U_PROMPT/$U_COMPLETION/$U_TOTAL"
    case "$U_COST_SOURCE" in
        upstream|computed|unknown) assert_eq "usage_log cost_source is valid enum" "$U_COST_SOURCE" "$U_COST_SOURCE" ;;
        *) assert_eq "usage_log cost_source is valid enum" "upstream|computed|unknown" "$U_COST_SOURCE" ;;
    esac
    # Model must be canonicalized by model_registry.canonical(): lowercase,
    # last path segment (provider prefix stripped). The local model id is
    # /zip/<name>.gguf -> <name>.gguf lowercased (registry alias).
    assert_eq "usage_log.model is populated (non-empty)" "yes" "$([ -n "$U_MODEL" ] && echo yes || echo no)"
    assert_eq "usage_log.model is normalized (lowercase)" "true" "$([ "$U_MODEL" = "$(printf '%s' "$U_MODEL" | tr 'A-Z' 'a-z')" ] && echo true || echo false)"
    EXPECTED_NORM=$(printf '%s' "$MODEL_ID" | sed 's|.*/||' | tr 'A-Z' 'a-z')
    assert_eq "usage_log.model matches canonical(model id)" "$EXPECTED_NORM" "$U_MODEL"
    assert_eq "usage_log tokens persisted > 0 (prompt)" "true" "$([ "${U_PROMPT:-0}" -gt 0 ] && echo true || echo false)"
    assert_eq "usage_log tokens persisted > 0 (total)" "true" "$([ "${U_TOTAL:-0}" -gt 0 ] && echo true || echo false)"
fi

echo ""
echo "llamafile e2e tests: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi