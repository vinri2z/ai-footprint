#!/usr/bin/env bash
# persist-session.sh — Stop hook: keep today's footprint fresh.
#
# Since tokscale is the single source of persisted usage, the Stop hook no longer parses JSONL.
# It re-ingests *today's* bucket (all agents, not just this Claude Code session) via
# ingest-tokscale.sh --today, which upserts on (date, client, provider, model) — so running it
# repeatedly is cheap and idempotent. Throttled and fully detached so it never blocks Claude.
# Intentionally no set -euo pipefail: this hook must exit 0 silently in all cases.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_DIR="${HOME}/.claude/claude-carbon"
DB_PATH="${CLAUDE_CARBON_DB:-${DB_DIR}/carbon.db}"
STAMP="${DB_DIR}/.last-ingest-today"
THROTTLE_SECONDS="${CLAUDE_FOOTPRINT_INGEST_THROTTLE:-300}"

# Drain stdin so the hook never blocks on an unread pipe
cat >/dev/null 2>&1 || true

# Exit silently if the plugin isn't set up yet
[ -f "$DB_PATH" ] || exit 0

# Throttle: skip if today's bucket was refreshed within THROTTLE_SECONDS
if [ -f "$STAMP" ]; then
  MTIME="$(stat -f %m "$STAMP" 2>/dev/null || stat -c %Y "$STAMP" 2>/dev/null || echo 0)"
  AGE=$(( $(date +%s) - MTIME ))
  [ "$AGE" -lt "$THROTTLE_SECONDS" ] && exit 0
fi

# Mark now, then re-ingest today detached so the session is never delayed.
touch "$STAMP" 2>/dev/null || true
( setsid bash "${SCRIPT_DIR}/ingest-tokscale.sh" --today >/dev/null 2>&1 < /dev/null & ) >/dev/null 2>&1 || \
  ( bash "${SCRIPT_DIR}/ingest-tokscale.sh" --today >/dev/null 2>&1 < /dev/null & ) >/dev/null 2>&1

exit 0
