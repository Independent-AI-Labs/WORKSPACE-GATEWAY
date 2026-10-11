#!/bin/bash
set -euo pipefail

# Guards the gateway maintenance systemd units (rendered from
# res/ansible/templates/). Regressions this catches:
#  - the cruncher unit carried NoNewPrivileges/PrivateTmp, which strip the
#    host-exec shell guard's file capability, so every nightly run exited 3
#    and request_signals never advanced;
#  - the units did not set PODMAN_PATH, so scripts resolved the unsanctioned
#    /usr/local/bin/podman wrapper (permission denied).

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
    _SELF="$SHG_SCRIPT_PATH"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass=0
fail=0

assert_eq() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "[PASS] $desc"
        pass=$((pass + 1))
    else
        echo "[FAIL] $desc -- expected: $expected, actual: $actual"
        fail=$((fail + 1))
    fi
}

count_in() {
    local needle="$1"
    local file="$2"
    local n
    n=$(grep -c "$needle" "$file") || { n="0"; }
    printf '%s' "$n"
}

has_in() {
    local needle="$1"
    local file="$2"
    local n
    n=$(count_in "$needle" "$file")
    if [ "$n" -ge 1 ]; then printf 'true'; else printf 'false'; fi
}

file_exists() {
    if [ -f "$1" ]; then printf '1'; else printf '0'; fi
}

summary() {
    echo ""
    echo "test_systemd_units.sh: $pass passed, $fail failed"
    if [ "$fail" -gt 0 ]; then
        exit 1
    fi
}

TEMPLATES="$REPO_ROOT/res/ansible/templates"
for unit in gateway-usefulness-crunch gateway-ch-backup gateway-model-attribution-check gateway-compose-healthcheck; do
    f="$TEMPLATES/$unit.service.j2"
    assert_eq "$unit.service.j2 exists" "1" "$(file_exists "$f")"
    assert_eq "$unit.service.j2 has no NoNewPrivileges directive" "0" "$(count_in '^NoNewPrivileges=' "$f")"
    assert_eq "$unit.service.j2 has no PrivateTmp directive" "0" "$(count_in '^PrivateTmp=' "$f")"
    assert_eq "$unit.service.j2 loads .env (CH credentials)" "true" "$(has_in 'EnvironmentFile={{ project_root }}/\.env' "$f")"
    assert_eq "$unit.service.j2 sets PODMAN_PATH from the template var" "true" "$(has_in 'Environment=PODMAN_PATH={{ podman_path }}' "$f")"
    assert_eq "$unit.service.j2 is Type=oneshot" "true" "$(has_in 'Type=oneshot' "$f")"
done
# The backup script must consume PODMAN_PATH (not a bare `podman`).
assert_eq "gateway-ch-backup.sh honours PODMAN_PATH" "true" \
    "$(has_in 'PODMAN="${PODMAN:-${PODMAN_PATH:-podman}}"' "$REPO_ROOT/res/scripts/gateway-ch-backup.sh")"

# Destination and retention are required configuration (REQ-SECURITY-HARDENING
# FR-4.5/FR-4.6): the job reads the one destination from .env and carries no
# built-in path.
BACKUP_SH="$REPO_ROOT/res/scripts/gateway-ch-backup.sh"
assert_eq "gateway-ch-backup.sh requires GW_BACKUP_DIR" "true" \
    "$(has_in 'GW_BACKUP_DIR:?GW_BACKUP_DIR not set' "$BACKUP_SH")"
assert_eq "gateway-ch-backup.sh requires GW_BACKUP_KEEP" "true" \
    "$(has_in 'GW_BACKUP_KEEP:?GW_BACKUP_KEEP not set' "$BACKUP_SH")"
assert_eq "gateway-ch-backup.sh has no built-in destination path" "0" \
    "$(count_in 'GW_BACKUP_DIR:-' "$BACKUP_SH")"
assert_eq "gateway-ch-backup.sh has no built-in retention count" "0" \
    "$(count_in 'GW_BACKUP_KEEP:-' "$BACKUP_SH")"
assert_eq "gateway-ch-backup.sh refuses a root-filesystem destination" "true" \
    "$(has_in 'backups must land on a separate mount' "$BACKUP_SH")"

for timer in gateway-usefulness-crunch gateway-ch-backup gateway-model-attribution-check gateway-compose-healthcheck; do
    f="$TEMPLATES/$timer.timer.j2"
    assert_eq "$timer.timer.j2 exists" "1" "$(file_exists "$f")"
    assert_eq "$timer.timer.j2 has OnCalendar" "true" "$(has_in 'OnCalendar=' "$f")"
    assert_eq "$timer.timer.j2 binds its service" "true" "$(has_in "Unit=$timer.service" "$f")"
done

# Deployment automation must render + enable the maintenance units (NFR-1.6).
ANSIBLE="$REPO_ROOT/res/ansible/compose.yml"
assert_eq "ansible renders maintenance templates" "true" "$(has_in 'templates/{{ item }}.j2' "$ANSIBLE")"
assert_eq "ansible timers tag present" "true" "$(has_in 'tags: \[deploy, timers, start, restart\]' "$ANSIBLE")"
assert_eq "ansible enables maintenance timers" "true" "$(has_in 'Enable gateway maintenance timers' "$ANSIBLE")"

# The manual install target must go through the same rendering path.
MAKEFILE="$REPO_ROOT/Makefile"
assert_eq "Makefile deploys maintenance timers via ansible" "true" "$(has_in 'ANSIBLE_COMPOSE) --tags timers' "$MAKEFILE")"
assert_eq "Makefile exposes gw-install-timers" "true" "$(has_in '^gw-install-timers:' "$MAKEFILE")"
assert_eq "Makefile exposes gw-backup (runs the backup script)" "true" \
    "$(has_in '^gw-backup:.*' "$MAKEFILE")"
assert_eq "Makefile gw-backup invokes gateway-ch-backup.sh" "true" \
    "$(has_in 'res/scripts/gateway-ch-backup.sh' "$MAKEFILE")"
assert_eq "Makefile exposes gw-backup-status" "true" "$(has_in '^gw-backup-status:' "$MAKEFILE")"

STATUS_SH="$REPO_ROOT/res/scripts/gateway-backup-status.sh"
assert_eq "gateway-backup-status.sh exists" "1" "$(file_exists "$STATUS_SH")"
assert_eq "gateway-backup-status.sh requires GW_BACKUP_DIR" "true" \
    "$(has_in 'GW_BACKUP_DIR:?GW_BACKUP_DIR not set' "$STATUS_SH")"

# Stack healthcheck supervisor (AUDIT-GATEWAY-STACK-TEARDOWN-2026-10-03): probe
# the dev stack and recover with bounded `make gw-start` attempts. Regressions:
# the recovery action drifting off the sanctioned make target, or the attempt
# budget losing its 3-attempts / 5-minute bound.
HC_SH="$REPO_ROOT/res/scripts/gateway-compose-healthcheck.sh"
assert_eq "gateway-compose-healthcheck.sh exists" "1" "$(file_exists "$HC_SH")"
assert_eq "healthcheck recovers via make gw-start" "true" \
    "$(has_in 'make -C "${PROJECT_ROOT}" gw-start' "$HC_SH")"
assert_eq "healthcheck default is 3 attempts" "true" \
    "$(has_in 'GATEWAY_HEALTHCHECK_ATTEMPTS:-3' "$HC_SH")"
assert_eq "healthcheck default budget is 300s" "true" \
    "$(has_in 'GATEWAY_HEALTHCHECK_BUDGET:-300' "$HC_SH")"
assert_eq "healthcheck targets the dev unit" "true" \
    "$(has_in 'GATEWAY_UNIT:-gateway-compose.service' "$HC_SH")"
assert_eq "ansible registers the healthcheck unit" "true" \
    "$(has_in 'gateway-compose-healthcheck.service' "$ANSIBLE")"
assert_eq "ansible enables the healthcheck timer" "true" \
    "$(has_in 'gateway-compose-healthcheck.timer' "$ANSIBLE")"
assert_eq "Makefile exposes gw-healthcheck" "true" "$(has_in '^gw-healthcheck:' "$MAKEFILE")"
assert_eq "Makefile gw-healthcheck runs the script" "true" \
    "$(has_in 'res/scripts/gateway-compose-healthcheck.sh' "$MAKEFILE")"

summary
