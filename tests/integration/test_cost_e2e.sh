#!/bin/bash
set -euo pipefail

# tests/integration/test_cost_e2e.sh
#
# End-to-end cost / billing-ledger test through the LOCAL llamafile upstream.
# Sends one non-streaming chat request via /llamafile/*, then asserts the
# resulting usage_log row has a valid cost_source enum value, a populated cost
# column, and (because model_registry.canonical strips the provider prefix) a
# canonical model value. Also asserts billing_ledger_mv carries the matching
# row (the MV fires automatically on usage_log INSERT).
#
# Uses the llamafile route exclusively. There is NO secondary path. If the
# llamafile server or the gateway stack is not reachable, the test SKIPS.

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
    echo "cost E2E tests: skipped (endpoint unreachable)"
    exit 0
fi

if ! llamafile_reachable; then
    echo "[SKIP] relay-llamafile upstream not reachable at $GATEWAY_URL/llamafile/v1/models"
    echo "       (start it: make install-llamafile MODEL=minicpm5-1b on the VM)"
    echo ""
    echo "cost E2E tests: skipped (llamafile not running)"
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
    echo "cost E2E tests: $pass passed, $fail failed"
    exit 1
fi
echo "[INFO] using model id: $MODEL_ID"

# Send one non-streaming chat request; capture X-Request-Id.
RESP_HEADERS=$(mktemp)
RESP_BODY=$(mktemp)
HTTP_CODE_RC=0
HTTP_CODE=$(curl -sS -D "$RESP_HEADERS" -o "$RESP_BODY" -w "%{http_code}" --max-time 120 \
    -X POST "$GATEWAY_URL/llamafile/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$MODEL_ID\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello\"}],\"stream\":false}" \
    ) || { HTTP_CODE_RC=$?; HTTP_CODE="000"; }
LIVE_RID_RC=0
LIVE_RID=$(grep -i '^x-request-id:' "$RESP_HEADERS" | sed 's/^[Xx]-[Rr]equest-[Ii]d:[[:space:]]*//; s/\r$//' ) || { LIVE_RID_RC=$?; LIVE_RID=""; }
rm -f "$RESP_HEADERS" "$RESP_BODY"

echo "[INFO] chat HTTP $HTTP_CODE X-Request-Id=$LIVE_RID"
assert_eq "chat request through gateway returned 200" "200" "$HTTP_CODE"
assert_eq "response carries X-Request-Id header" "yes" "$(if [ -n "$LIVE_RID" ]; then printf 'yes'; else printf 'no'; fi)"

if [ "$HTTP_CODE" != "200" ] || [ -z "$LIVE_RID" ]; then
    echo ""
    echo "cost E2E tests: $pass passed, $fail failed"
    [ "$fail" -gt 0 ] && exit 1
    exit 0
fi

# Poll usage_log for the row matching THIS request_id.
U_EID=""
ULOG=""
for i in $(seq 1 25); do
    ULOG=$(ch_query "$(sql_render tests/cost-e2e/usage-row.sql "RID=$LIVE_RID")")
    [ -n "$ULOG" ] && break
    sleep 1
done
if [ -n "$ULOG" ]; then
    U_EID=$(printf '%s' "$ULOG" | cut -f1)
    ULOG=$(printf '%s' "$ULOG" | cut -f2-)
fi
assert_eq "usage_log row appears for this run's request_id" "yes" "$(if [ -n "$ULOG" ]; then printf 'yes'; else printf 'no'; fi)"
if [ -z "$ULOG" ]; then
    echo ""
    echo "cost E2E tests: $pass passed, $fail failed"
    exit 1
fi

U_COST_SOURCE=$(printf '%s' "$ULOG" | cut -f1)
U_COST=$(printf '%s' "$ULOG" | cut -f2)
U_MODEL=$(printf '%s' "$ULOG" | cut -f3)
U_PROMPT=$(printf '%s' "$ULOG" | cut -f4)
U_COMPLETION=$(printf '%s' "$ULOG" | cut -f5)
U_TOTAL=$(printf '%s' "$ULOG" | cut -f6)
echo "[INFO] usage_log row: cost_source=$U_COST_SOURCE cost=$U_COST model=$U_MODEL tokens=$U_PROMPT/$U_COMPLETION/$U_TOTAL"

case "$U_COST_SOURCE" in
    provider_override|models_dev|unknown)
        assert_eq "usage_log cost_source is a valid enum" "$U_COST_SOURCE" "$U_COST_SOURCE" ;;
    *)
        assert_eq "usage_log cost_source is a valid enum" "provider_override|models_dev|unknown" "$U_COST_SOURCE" ;;
esac

# Local llamafile model has no models.dev price, so cost_source is "unknown";
# cost must be 0 - no hallucinated cost.
if [ "$U_COST_SOURCE" = "unknown" ]; then
    assert_eq "usage_log cost == 0 for unpriced local model (no hallucinated cost)" "0" "$U_COST"
else
    assert_eq "usage_log cost > 0 for priced model" "true" "$(if [ "$U_COST" != "0" ]; then printf 'true'; else printf 'false'; fi)"
fi

# Model must be canonicalized by model_registry.canonical(): lowercase + last
# path segment (provider prefix stripped); registry aliases collapse to the
# canonical id.
EXPECTED_NORM=$(printf '%s' "$MODEL_ID" | sed 's|.*/||' | tr 'A-Z' 'a-z')
assert_eq "usage_log.model matches canonical(model id)" "$EXPECTED_NORM" "$U_MODEL"
assert_eq "usage_log.prompt_tokens > 0" "true" "$(if [ "${U_PROMPT:-0}" -gt 0 ]; then printf 'true'; else printf 'false'; fi)"
assert_eq "usage_log.total_tokens > 0" "true" "$(if [ "${U_TOTAL:-0}" -gt 0 ]; then printf 'true'; else printf 'false'; fi)"

# billing_ledger_mv must carry the matching row (auto-populated on INSERT).
# billing_ledger is keyed by event_id (the MV maps usage_log.event_id -> ledger)
# and uses model_name (not model); request_id / cost_source are not on the ledger.
if [ -z "$U_EID" ]; then
    assert_eq "billing_ledger lookup needs usage_log.event_id" "yes" "no"
else
    LEDGER=""
    for i in $(seq 1 25); do
        LEDGER=$(ch_query "$(sql_render tests/cost-e2e/ledger-row.sql "EID=$U_EID")")
        [ -n "$LEDGER" ] && break
        sleep 1
    done
    assert_eq "billing_ledger row appears for this run's event_id" "yes" "$(if [ -n "$LEDGER" ]; then printf 'yes'; else printf 'no'; fi)"
    if [ -n "$LEDGER" ]; then
        L_EID=$(printf '%s' "$LEDGER" | cut -f1)
        L_MODEL_NAME=$(printf '%s' "$LEDGER" | cut -f2)
        L_COST=$(printf '%s' "$LEDGER" | cut -f3)
        L_PROMPT=$(printf '%s' "$LEDGER" | cut -f4)
        L_TOTAL=$(printf '%s' "$LEDGER" | cut -f5)
        echo "[INFO] billing_ledger row: event_id=$L_EID model_name=$L_MODEL_NAME cost=$L_COST tokens=$L_PROMPT/$L_TOTAL"
        assert_eq "billing_ledger.event_id matches usage_log.event_id" "$U_EID" "$L_EID"
        assert_eq "billing_ledger.model_name matches usage_log.model (MV copies it)" "$U_MODEL" "$L_MODEL_NAME"
        assert_eq "billing_ledger.cost matches usage_log.cost (rounded to 6)" "$U_COST" "$(printf '%s' "$L_COST" | tr -d ' ')"
        assert_eq "billing_ledger.prompt_tokens matches usage_log" "$U_PROMPT" "$L_PROMPT"
        assert_eq "billing_ledger.total_tokens matches usage_log" "$U_TOTAL" "$L_TOTAL"
    fi
fi

echo ""
echo "cost E2E tests: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi
