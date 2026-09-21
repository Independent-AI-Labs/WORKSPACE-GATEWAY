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

# Renderers for the conf/sql/test templates (caller sets REPO_ROOT).
: "${REPO_ROOT:?lib_event_align.sh requires REPO_ROOT}"
export REPO_ROOT
# shellcheck source=../../res/scripts/lib-sql.sh
source "$REPO_ROOT/res/scripts/lib-sql.sh" || return 1

setup_endpoints() {
    # Returns 0 if both endpoints are reachable, 1 otherwise.
    curl_code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 5 "$GATEWAY_URL/" )
    if [ "$curl_code" = "000" ]; then
        echo "[SKIP] APISIX not reachable at $GATEWAY_URL"
        return 1
    fi
    ch_health_RC=0
    ch_health=$(curl -fsS --max-time 5 "$CH_URL/ping" ) || { ch_health_RC=$?; ch_health=""; }
    if [ "$ch_health" != "1" ] && [ "$ch_health" != "Ok." ]; then
        echo "[SKIP] ClickHouse not reachable at $CH_URL"
        return 1
    fi
    if [ -z "${CH_OPS_PASSWORD:-}" ]; then
        echo "[SKIP] CH_OPS_PASSWORD not set (source repo .env) - queries need ops_admin auth"
        return 1
    fi
    return 0
}

ch_query() (
    cfg="$(mktemp)"
    trap 'rm -f "$cfg"' EXIT
    printf 'user = "%s:%s"\n' "${CH_OPS_USER:-ops_admin}" "$CH_OPS_PASSWORD" > "$cfg"
    curl -fsS --max-time 15 -G \
        --config "$cfg" \
        "$CH_URL/" --data-urlencode "query=$1 FORMAT TabSeparated"
)

count_recent() {
    local table="$1" boundary="$2"
    local where=""
    [ "$boundary" -gt 0 ] && where="AND toUInt32(toDateTime(timestamp)) >= $boundary"
    ch_query "$(sql_render tests/event-align/count-recent.sql "TABLE=$table" "WHERE=$where")" | tr -d ' \n'
}

latest_pair() {
    local table="$1" boundary="$2"
    local where=""
    [ "$boundary" -gt 0 ] && where="AND toUInt32(toDateTime(timestamp)) >= $boundary"
    ch_query "$(sql_render tests/event-align/latest-pair.sql "TABLE=$table" "WHERE=$where")"
}

pair_by_rid() {
    local table="$1" rid="$2"
    ch_query "$(sql_render tests/event-align/pair-by-rid.sql "TABLE=$table" "RID=$rid")"
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
    assert_eq "usage_log.request_id is populated (non-empty)" "yes" "$(if [ -n "$u_rid" ]; then printf 'yes'; else printf 'no'; fi)"
    assert_eq "usage_log.event_id is not the earlier constant relay-opencode_0" "no" "$(if [ "$u_eid" = "relay-opencode_0" ]; then printf 'yes'; else printf 'no'; fi)"
    assert_eq "request_log row found for the same request_id" "yes" "$(if [ -n "$r_eid" ]; then printf 'yes'; else printf 'no'; fi)"
    assert_eq "request_log.request_id is populated (non-empty)" "yes" "$(if [ -n "$r_rid" ]; then printf 'yes'; else printf 'no'; fi)"
    if [ -n "$r_eid" ] && [ -n "$u_eid" ]; then
        assert_eq "request_id matches between usage_log and request_log" "$u_rid" "$r_rid"
        assert_eq "event_id matches between usage_log and request_log" "$u_eid" "$r_eid"
        # event_id suffix must be integer-seconds (10-11 digit epoch), proving
        # the earlier constant-suffix bug is gone on BOTH write paths.
        u_suffix="$(printf '%s' "$u_eid" | sed 's/^.*_\([0-9]\+\)$/\1/')"
        assert_eq "usage_log.event_id suffix is integer-seconds epoch" "true" \
            "$(if [ "${#u_suffix}" -ge 10 ] && [ "${#u_suffix}" -le 11 ]; then printf 'true'; else printf 'false'; fi)"
    fi
}

# Detect whether the local llamafile upstream is reachable through the
# gateway's /llamafile route. Returns 0 (reachable) / 1 (not). Used by tests
# to decide whether to exercise the no-credit local LLM path.
llamafile_reachable() {
    local code
    code_RC=0
    code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 5 \
        "$GATEWAY_URL/llamafile/v1/models" ) || { code_RC=$?; code="000"; }
    [ "$code" != "000" ] && [ "$code" != "404" ]
}
