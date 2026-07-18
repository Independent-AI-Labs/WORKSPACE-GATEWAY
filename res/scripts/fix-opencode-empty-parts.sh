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

ISSUES=$(sqlite3 "$DB" "
SELECT count(*) FROM part
WHERE (json_extract(data,'$.type')='reasoning' AND json_extract(data,'$.text')='')
   OR (json_extract(data,'$.type')='text' AND json_extract(data,'$.text')=''
       AND json_extract((SELECT m.data FROM message m WHERE m.id=part.message_id),'$.role')='assistant');
")

echo "[INFO] $DB: $ISSUES empty content part(s) found"

if [ "$ISSUES" -eq 0 ]; then
    exit 0
fi

if [ "$MODE" = "check" ]; then
    sqlite3 "$DB" "
SELECT p.id, m.session_id, json_extract(p.data,'$.type')
FROM part p JOIN message m ON m.id = p.message_id
WHERE (json_extract(p.data,'$.type')='reasoning' AND json_extract(p.data,'$.text')='')
   OR (json_extract(p.data,'$.type')='text' AND json_extract(p.data,'$.text')=''
       AND json_extract(m.data,'$.role')='assistant');"
    exit 1
fi

BACKUP="$DB.bak.$(date +%Y%m%d%H%M%S)"
cp "$DB" "$BACKUP"
echo "[INFO] backup: $BACKUP"

NOW_MS=$(($(date +%s) * 1000))

sqlite3 "$DB" <<SQL
UPDATE part
SET data = json_set(data, '\$.text', '[reasoning interrupted]'),
    time_updated = $NOW_MS
WHERE json_extract(data,'$.type')='reasoning' AND json_extract(data,'$.text')='';

UPDATE part
SET data = json_set(data, '\$.text', ' '),
    time_updated = $NOW_MS
WHERE json_extract(data,'$.type')='text' AND json_extract(data,'$.text')=''
  AND json_extract((SELECT m.data FROM message m WHERE m.id=part.message_id),'$.role')='assistant';
SQL

REMAINING=$(sqlite3 "$DB" "
SELECT count(*) FROM part
WHERE (json_extract(data,'$.type')='reasoning' AND json_extract(data,'$.text')='')
   OR (json_extract(data,'$.type')='text' AND json_extract(data,'$.text')=''
       AND json_extract((SELECT m.data FROM message m WHERE m.id=part.message_id),'$.role')='assistant');
")

if [ "$REMAINING" -ne 0 ]; then
    echo "[FAIL] $REMAINING empty part(s) remain after repair" >&2
    exit 1
fi

echo "[OK] repaired $ISSUES empty content part(s)"
