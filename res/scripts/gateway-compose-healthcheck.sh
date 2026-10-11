#!/usr/bin/env bash
# gateway-compose-healthcheck.sh - dev-stack liveness supervisor.
#
# Container restart policies (restart: unless-stopped) cover a single lost
# service but cannot see a whole-stack exit or externally removed containers:
# on 2026-10-03 the unit went inactive and the stack stayed down unnoticed
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
PROBE_LOG="${GATEWAY_HEALTHCHECK_LOG:-/var/tmp/workspace-gateway-healthcheck.log}"
# Remote delivery is owned by WORKSPACE-STREAMS (mail channel). Until its
# himalaya config + OpenBao notify credentials are provisioned the call is
# non-fatal; absence of the binary is not a healthcheck failure.
NOTIFY_BIN="${WORKSPACE_NOTIFY_BIN:-${HOME}/WORKSPACE-VM/scripts/services/workspace_failure_notify.sh}"

log() { printf '[gateway-healthcheck] %s\n' "$*" >&2; }

# Healthy = the unit is active AND the APISIX data plane answers AND ClickHouse
# answers. Readiness codes (404 from APISIX before route seeding) count as up.
probe() {
    local active code
    active="$(systemctl --user is-active "${GATEWAY_UNIT}" 2>>"${PROBE_LOG}")" || active="unknown"
    if [[ "${active}" != "active" ]]; then
        log "probe: unit ${GATEWAY_UNIT} is '${active}'"
        return 1
    fi

    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "${APISIX_URL}" 2>>"${PROBE_LOG}")" || code=000
    if [[ "${code}" != "200" && "${code}" != "404" ]]; then
        log "probe: APISIX ${APISIX_URL} -> ${code}"
        return 1
    fi

    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "${CLICKHOUSE_URL}" 2>>"${PROBE_LOG}")" || code=000
    if [[ "${code}" != "200" ]]; then
        log "probe: ClickHouse ${CLICKHOUSE_URL} -> ${code}"
        return 1
    fi

    return 0
}

recover() {
    local attempt=0 start now elapsed sendrc
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
        sendrc=0
        timeout "${ATTEMPT_TIMEOUT}" make -C "${PROJECT_ROOT}" gw-start || sendrc=$?
        if (( sendrc != 0 )); then
            log "make gw-start returned status ${sendrc} (attempt ${attempt}); re-probing"
        fi
        if probe; then
            log "recovered after ${attempt} attempt(s)"
            return 0
        fi
    done
    return 1
}

notify_failure() {
    local sendrc=0
    # Local popup: non-fatal (the compositor may be down in the freeze class
    # this workstation sees; harmless when it is up).
    notify-send "WORKSPACE-GATEWAY dev stack DOWN" \
        "${GATEWAY_UNIT} did not recover after ${MAX_ATTEMPTS} attempts; see journalctl --user -u ${GATEWAY_UNIT}" \
        || sendrc=$?
    if (( sendrc != 0 )); then
        log "notify-send unavailable (status ${sendrc})"
    fi

    if [[ -x "${NOTIFY_BIN}" ]]; then
        sendrc=0
        "${NOTIFY_BIN}" "${GATEWAY_UNIT}" || sendrc=$?
        log "remote notifier status ${sendrc} (mail delivery pending WORKSPACE-STREAMS provisioning)"
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