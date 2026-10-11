#!/bin/bash
# gateway-compose-healthcheck.sh - dev-stack liveness supervisor.
#
# Container restart policies (restart: unless-stopped) cover a single crashed
# service but cannot see a whole-stack exit or externally removed containers:
# on 2026-10-03 the unit went inactive and the stack stayed down with no alert
# (AUDIT-GATEWAY-STACK-TEARDOWN-2026-10-03). This probes the dev stack and, when
# it is down, recovers with `make gw-start` up to MAX_ATTEMPTS within a bounded
# budget, then alerts.
#
# Dev only: targets the gateway-compose.service dev unit (not the prod pod).
#
# Usage:
#   gateway-compose-healthcheck.sh           # probe, recover on failure
#   gateway-compose-healthcheck.sh --probe   # probe once, no recovery
#
# Exit codes:
#   0  healthy, or recovered
#   1  still down after all recovery attempts (alert raised)
#   2  bad invocation
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"

GATEWAY_UNIT="${GATEWAY_UNIT:-gateway-compose.service}"
APISIX_URL="${GATEWAY_APISIX_URL:-http://localhost:9080/}"
CLICKHOUSE_URL="${GATEWAY_CLICKHOUSE_URL:-http://localhost:8123/ping}"
MAX_ATTEMPTS="${GATEWAY_HEALTHCHECK_ATTEMPTS:-3}"
BUDGET_SECS="${GATEWAY_HEALTHCHECK_BUDGET:-300}"
# ponytail: fixed per-attempt bound. A cold boot can consume one attempt; the
# remaining attempts cover it. Raise if the stack's start time grows past this.
ATTEMPT_TIMEOUT="${GATEWAY_HEALTHCHECK_ATTEMPT_TIMEOUT:-90}"
# Remote delivery is owned by WORKSPACE-STREAMS (mail channel). Until its
# himalaya config + OpenBao notify credentials are provisioned the call is
# skipped when the binary is absent; that absence is not a healthcheck failure.
NOTIFY_BIN="${WORKSPACE_NOTIFY_BIN:-${HOME}/WORKSPACE-VM/scripts/services/workspace_failure_notify.sh}"

log() { printf '[gateway-healthcheck] %s\n' "$*" >&2; }

# Healthy = the unit is active AND the APISIX data plane answers AND ClickHouse
# answers. Readiness codes (404 from APISIX before route seeding) count as up.
probe() {
    local active code result
    result=0
    active="$(systemctl --user is-active "${GATEWAY_UNIT}")" || result=$?
    if (( result != 0 )); then
        log "probe: systemctl is-active ${GATEWAY_UNIT} result=${result} (state=${active:-none})"
    fi
    if [[ "${active}" != "active" ]]; then
        log "probe: unit ${GATEWAY_UNIT} is '${active:-unknown}'"
        return 1
    fi

    result=0
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "${APISIX_URL}")" || result=$?
    if (( result != 0 )); then
        log "probe: APISIX ${APISIX_URL} request failed result=${result}"
    fi
    code="${code:-000}"
    if [[ "${code}" != "200" && "${code}" != "404" ]]; then
        log "probe: APISIX ${APISIX_URL} -> ${code}"
        return 1
    fi

    result=0
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "${CLICKHOUSE_URL}")" || result=$?
    if (( result != 0 )); then
        log "probe: ClickHouse ${CLICKHOUSE_URL} request failed result=${result}"
    fi
    code="${code:-000}"
    if [[ "${code}" != "200" ]]; then
        log "probe: ClickHouse ${CLICKHOUSE_URL} -> ${code}"
        return 1
    fi

    return 0
}

recover() {
    local attempt=0 start now elapsed result
    start="$(date +%s)"
    while (( attempt < MAX_ATTEMPTS )); do
        attempt=$((attempt + 1))
        now="$(date +%s)"
        elapsed=$((now - start))
        if (( elapsed >= BUDGET_SECS )); then
            log "recovery budget ${BUDGET_SECS}s exhausted before attempt ${attempt}"
            return 1
        fi
        log "recovery attempt ${attempt}/${MAX_ATTEMPTS} (elapsed ${elapsed}s): make gw-start"
        result=0
        timeout "${ATTEMPT_TIMEOUT}" make -C "${PROJECT_ROOT}" gw-start || result=$?
        if (( result != 0 )); then
            log "make gw-start returned result=${result} (attempt ${attempt}); re-probing"
        fi
        if probe; then
            log "recovered after ${attempt} attempt(s)"
            return 0
        fi
    done
    return 1
}

notify_failure() {
    local result=0
    # Local popup: fire-and-forget (the compositor may be down in the freeze
    # class this workstation sees; harmless when it is up).
    notify-send "WORKSPACE-GATEWAY dev stack DOWN" \
        "${GATEWAY_UNIT} did not recover after ${MAX_ATTEMPTS} attempts; see journalctl --user -u ${GATEWAY_UNIT}" \
        || result=$?
    if (( result != 0 )); then
        log "notify-send unavailable (result=${result})"
    fi

    if [[ -x "${NOTIFY_BIN}" ]]; then
        result=0
        "${NOTIFY_BIN}" "${GATEWAY_UNIT}" || result=$?
        log "remote notifier result=${result} (mail delivery pending WORKSPACE-STREAMS provisioning)"
    else
        log "remote alert path not provisioned: ${NOTIFY_BIN} absent (WORKSPACE-STREAMS mail channel pending)"
    fi
}

main() {
    local probe_only=0
    case "${1:-}" in
        --probe) probe_only=1 ;;
        "") : ;;
        *) echo "usage: $0 [--probe]" >&2; exit 2 ;;
    esac

    if probe; then
        log "healthy"
        exit 0
    fi

    log "stack is DOWN"
    if (( probe_only )); then
        exit 1
    fi

    if recover; then
        exit 0
    fi

    log "stack still DOWN after ${MAX_ATTEMPTS} attempt(s) within ${BUDGET_SECS}s"
    notify_failure
    exit 1
}

main "$@"