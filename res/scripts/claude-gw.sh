#!/bin/bash
set -euo pipefail

# claude-gw.sh
# Start Claude Code with the WORKSPACE gateway as its Anthropic backend.
#
# The only thing redirected is the API endpoint: ANTHROPIC_BASE_URL. The
# gateway's /anthropic route (REQ/SPEC-PROVIDER-ANTHROPIC) bare-proxies
# api.anthropic.com and passes ALL auth through untouched, so the CLI
# keeps using its own standard mechanisms: /login runs the normal
# browser flow against claude.ai, credentials stay in the CLI's own
# store, refresh goes through the CLI as usual, and every request
# carries the CLI's own Authorization header to the gateway, which
# relays it upstream verbatim. The user sets no tokens, no keys,
# nothing.
#
# Environment overrides (all optional):
#   GW_BASE_URL  gateway origin (default: https://gw.workspaceguardrails.com)
#   GW_ROUTE     Anthropic route prefix (default: /anthropic)
#   CLAUDE_BIN   claude executable (default: claude from PATH)
#   WORKSPACE_GUARD_SANITIZED_SINK  guard strip-report sink
#                (default set below: liveaudit; override to stderr to
#                restore terminal delivery)
#
# Usage: bash res/scripts/claude-gw.sh [claude args...]

GW_BASE_URL="${GW_BASE_URL:-https://gw.workspaceguardrails.com}"
GW_ROUTE="${GW_ROUTE:-/anthropic}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"

# Claude Code shells out to git constantly and parses its output; a
# SANITIZED report on stderr for every read-only query would corrupt
# that. Divert guard strip reports to the .liveaudit file in the
# working directory ONLY: in liveaudit mode the guard writes nothing to
# stdout, stderr, or the tty. Pre-set values pass through untouched so
# an operator can force stderr delivery explicitly.
export WORKSPACE_GUARD_SANITIZED_SINK="${WORKSPACE_GUARD_SANITIZED_SINK:-liveaudit}"
export WORKSPACE_GUARD_BLOCK_SINK="${WORKSPACE_GUARD_BLOCK_SINK:-liveaudit}"

if ! command -v "$CLAUDE_BIN" 1>&2; then
    echo "ERROR: claude not found. Install: curl -fsSL https://claude.ai/install.sh | bash" >&2
    exit 1
fi

# Claude Code appends /v1/messages (and other /v1/* paths) to
# ANTHROPIC_BASE_URL itself. No other env is touched: any credentials
# the CLI manages on its own travel with each request, unchanged.
export ANTHROPIC_BASE_URL="${GW_BASE_URL%/}${GW_ROUTE}"

exec "$CLAUDE_BIN" "$@"
