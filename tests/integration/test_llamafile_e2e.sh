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
    echo "llamafile e2e tests: $pass passed, $fail failed"
    exit 1
fi
echo "[INFO] using model id: $MODEL_ID"

# Send a NON-STREAMING chat request, capturing the X-Request-Id response header.
RESP_HEADERS=$(mktemp)
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
assert_eq "llamafile chat/completions returned 200" "200" "$HTTP_CODE"
assert_eq "llamafile response carries X-Request-Id header" "yes" "$(if [ -n "$LIVE_RID" ]; then printf 'yes'; else printf 'no'; fi)"

if [ "$HTTP_CODE" != "200" ] || [ -z "$LIVE_RID" ]; then
    rm -f "$RESP_BODY"
    echo ""
    echo "llamafile e2e tests: $pass passed, $fail failed"
    [ "$fail" -gt 0 ] && exit 1
    exit 0
fi

# Verify the response body is valid JSON with a choices array (proves the
# upstream is a real LLM, not a stand-in). NOTE: the local llamafile server
# frequently returns usage = 0 in its response body - the sse-usage Lua
# plugin is responsible for estimating tokens in that case. Token-count
# correctness is therefore asserted from usage_log downstream, NOT from the
# raw HTTP response usage object.
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
assert_eq "request_log row appears for this run's request_id" "$LIVE_RID" "$(if [ -n "$R_RID" ]; then printf '%s' "$R_RID"; else printf '(none)'; fi)"

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
        provider_override|models_dev|unknown) assert_eq "usage_log cost_source is valid enum" "$U_COST_SOURCE" "$U_COST_SOURCE" ;;
        *) assert_eq "usage_log cost_source is valid enum" "provider_override|models_dev|unknown" "$U_COST_SOURCE" ;;
    esac
    # Model must be canonicalized by model_registry.canonical(): lowercase,
    # last path segment (provider prefix stripped). The local model id is
    # /zip/<name>.gguf -> <name>.gguf lowercased (registry alias).
    assert_eq "usage_log.model is populated (non-empty)" "yes" "$(if [ -n "$U_MODEL" ]; then printf 'yes'; else printf 'no'; fi)"
    assert_eq "usage_log.model is normalized (lowercase)" "true" "$(if [ "$U_MODEL" = "$(printf '%s' "$U_MODEL" | tr 'A-Z' 'a-z')" ]; then printf 'true'; else printf 'false'; fi)"
    EXPECTED_NORM=$(printf '%s' "$MODEL_ID" | sed 's|.*/||' | tr 'A-Z' 'a-z')
    assert_eq "usage_log.model matches canonical(model id)" "$EXPECTED_NORM" "$U_MODEL"
    assert_eq "usage_log tokens persisted > 0 (prompt)" "true" "$(if [ "${U_PROMPT:-0}" -gt 0 ]; then printf 'true'; else printf 'false'; fi)"
    assert_eq "usage_log tokens persisted > 0 (total)" "true" "$(if [ "${U_TOTAL:-0}" -gt 0 ]; then printf 'true'; else printf 'false'; fi)"
fi

echo ""
echo "llamafile e2e tests: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi
