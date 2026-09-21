#!/bin/bash
# fix-opencode-empty-parts.sh - Detect and repair zero-length content parts in
# the opencode session database (opencode.db).
#
# When the gateway is restarted mid-stream, opencode can persist assistant
# messages whose reasoning or text parts are empty strings. On replay,
# session/message-v2.ts toModelMessages converts such steps into
# {"role":"assistant","content":""}, which OpenAI-compatible upstreams reject
# with: "the message at position N with role 'assistant' must not be empty".
#
# This script patches the offending PARTS IN PLACE (nothing is deleted):
#   - empty reasoning text -> '[reasoning interrupted]'
#   - empty assistant text -> ' ' (single space, same separator opencode uses)
#
# Usage:
#   fix-opencode-empty-parts.sh           scan and repair (with backup)
#   fix-opencode-empty-parts.sh --check   scan only, exit 1 if issues found
#
# Env:
#   OPENCODE_DB   path to opencode.db (default: ~/.local/share/opencode/opencode.db)
set -euo pipefail

_SELF="${BASH_SOURCE[0]}"
case "$_SELF" in
    /proc/*) _SELF="${SHG_SCRIPT_PATH:-$_SELF}" ;;
esac
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
# /proc/fd execution (test runners) leaves SHG_SCRIPT_PATH unset; use the
# caller's working directory when it is the repo root.
if [ ! -f "$SCRIPT_DIR/lib-sql.sh" ] && [ -f "$PWD/res/scripts/lib-sql.sh" ]; then
    SCRIPT_DIR="$PWD/res/scripts"
fi
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
# shellcheck source=lib-sql.sh
source "$SCRIPT_DIR/lib-sql.sh" || exit 1

DB="${OPENCODE_DB:-$HOME/.local/share/opencode/opencode.db}"
MODE="fix"
if [ "${1:-}" = "--check" ]; then
    MODE="check"
elif [ "${1:-}" != "" ]; then
    echo "Usage: $0 [--check]" >&2
    exit 2
fi

if [ ! -f "$DB" ]; then
    echo "[FAIL] database not found: $DB" >&2
    exit 1
fi

ISSUES=$(sqlite3 "$DB" "$(sql_render sqlite/opencode-fix/count_empty.sql)")

echo "[INFO] $DB: $ISSUES empty content part(s) found"

if [ "$ISSUES" -eq 0 ]; then
    exit 0
fi

if [ "$MODE" = "check" ]; then
    sqlite3 "$DB" "$(sql_render sqlite/opencode-fix/list_empty.sql)"
    exit 1
fi

BACKUP="$DB.bak.$(date +%Y%m%d%H%M%S)"
cp "$DB" "$BACKUP"
echo "[INFO] backup: $BACKUP"

NOW_MS=$(($(date +%s) * 1000))

sqlite3 "$DB" "$(sql_render sqlite/opencode-fix/repair.sql NOW_MS="$NOW_MS")"

REMAINING=$(sqlite3 "$DB" "$(sql_render sqlite/opencode-fix/count_empty.sql)")

if [ "$REMAINING" -ne 0 ]; then
    echo "[FAIL] $REMAINING empty part(s) remain after repair" >&2
    exit 1
fi

echo "[OK] repaired $ISSUES empty content part(s)"
