#!/bin/bash
# tests/integration/lib_event_align.sh
#
# Shared helpers for integration tests that verify event_id / request_id
# alignment between usage_log (Lua sse-usage plugin) and request_log (Vector)
# for a single request flowing through the gateway.
#
# Source this file from an integration test AFTER sourcing .env. The caller
# must define `pass` and `fail` counter variables before calling assert_*.
# CH_URL and GATEWAY_URL are set here if not already exported by the caller.
#
# Provided functions:
#   setup_endpoints   - resolve CH_URL / GATEWAY_URL defaults + reachability
#   ch_query Q        - run a ClickHouse query, TabSeparated, return stdout
#   count_recent T B  - count rows in table T with non-empty request_id since
#                       epoch boundary B (0 = all rows)
#   latest_pair T B   - latest (event_id\trequest_id) row since boundary B
#   pair_by_rid T RID - (event_id\trequest_id) row matching request_id RID
#   assert_eq D E A   - equality assertion (increments pass/fail)
#   assert_alignment U_EID U_RID R_EID R_RID
#                     - assert usage_log & request_log share request_id AND
#                       event_id (the core alignment fix)

# Endpoint defaults (caller may override before sourcing).
: "${GATEWAY_URL:=http://localhost:9080}"
: "${CH_URL:=http://localhost:8123}"
export GATEWAY_URL CH_URL

setup_endpoints() {
    # Returns 0 if both endpoints are reachable, 1 otherwise.
    curl_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$GATEWAY_URL/" 2>/dev/null || echo "000")
    if [ "$curl_code" = "000" ]; then
        echo "[SKIP] APISIX not reachable at $GATEWAY_URL"
        return 1
    fi
    ch_health=$(curl -sf --max-time 5 "$CH_URL/?query=SELECT+1" 2>/dev/null || echo "")
    if [ "$ch_health" != "1" ]; then
        echo "[SKIP] ClickHouse not reachable at $CH_URL"
        return 1
    fi
    return 0
}

ch_query() {
    curl -sf --max-time 15 -G "$CH_URL/" --data-urlencode "query=$1 FORMAT TabSeparated" 2>/dev/null || echo ""
}

count_recent() {
    local table="$1" boundary="$2"
    local where=""
    [ "$boundary" -gt 0 ] 2>/dev/null && where="AND toUInt32(toDateTime(timestamp)) >= $boundary"
    ch_query "SELECT count() FROM llm_gateway.$table WHERE request_id != '' $where" | tr -d ' \n'
}

latest_pair() {
    local table="$1" boundary="$2"
    local where=""
    [ "$boundary" -gt 0 ] 2>/dev/null && where="AND toUInt32(toDateTime(timestamp)) >= $boundary"
    ch_query "SELECT event_id, request_id FROM llm_gateway.$table WHERE request_id != '' $where ORDER BY timestamp DESC LIMIT 1"
}

pair_by_rid() {
    local table="$1" rid="$2"
    ch_query "SELECT event_id, request_id FROM llm_gateway.$table WHERE request_id = '$rid' LIMIT 1"
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "[PASS] $desc"
        pass=$((pass + 1))
    else
        echo "[FAIL] $desc -- expected: [$expected], actual: [$actual]"
        fail=$((fail + 1))
    fi
}

# Core alignment assertion: request_id and event_id must match between the
# usage_log row (Lua) and the request_log row (Vector) for ONE request.
assert_alignment() {
    local u_eid="$1" u_rid="$2" r_eid="$3" r_rid="$4"
    assert_eq "usage_log.request_id is populated (non-empty)" "yes" "$([ -n "$u_rid" ] && echo yes || echo no)"
    assert_eq "usage_log.event_id is not the legacy constant relay-opencode_0" "no" "$([ "$u_eid" = "relay-opencode_0" ] && echo yes || echo no)"
    assert_eq "request_log row found for the same request_id" "yes" "$([ -n "$r_eid" ] && echo yes || echo no)"
    assert_eq "request_log.request_id is populated (non-empty)" "yes" "$([ -n "$r_rid" ] && echo yes || echo no)"
    if [ -n "$r_eid" ] && [ -n "$u_eid" ]; then
        assert_eq "request_id matches between usage_log and request_log" "$u_rid" "$r_rid"
        assert_eq "event_id matches between usage_log and request_log" "$u_eid" "$r_eid"
        # event_id suffix must be integer-seconds (10-11 digit epoch), proving
        # the legacy constant-suffix bug is gone on BOTH write paths.
        u_suffix="$(printf '%s' "$u_eid" | sed 's/^.*_\([0-9]\+\)$/\1/')"
        assert_eq "usage_log.event_id suffix is integer-seconds epoch" "true" \
            "$([ "${#u_suffix}" -ge 10 ] && [ "${#u_suffix}" -le 11 ] && echo true || echo false)"
    fi
}

# Detect whether the local llamafile upstream is reachable through the
# gateway's /llamafile route. Returns 0 (reachable) / 1 (not). Used by tests
# to decide whether to exercise the no-credit local LLM path.
llamafile_reachable() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
        "$GATEWAY_URL/llamafile/v1/models" 2>/dev/null || echo "000")
    [ "$code" != "000" ] && [ "$code" != "404" ]
}