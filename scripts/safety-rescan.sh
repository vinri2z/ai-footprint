#!/usr/bin/env bash
# safety-rescan.sh — SessionStart hook: a throttled, backgrounded tokscale re-ingest of the
# recent window that catches usage the Stop hook missed (crash, kill, hook disabled) and picks
# up other agents (Codex, Cursor, ...) used outside Claude Code. ingest-tokscale.sh upserts on
# (date, client, provider, model), so re-running a day is cheap and idempotent.
# Must exit 0 immediately and never block session start.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_DIR="${HOME}/.claude/claude-carbon"
DB_PATH="${CLAUDE_CARBON_DB:-${DB_DIR}/carbon.db}"
STAMP="${DB_DIR}/.last-rescan"

# Drain stdin so the hook never blocks on an unread pipe
cat >/dev/null 2>&1 || true

# Only if the plugin is set up
[ -f "$DB_PATH" ] || exit 0

# Throttle: skip if a rescan ran in the last 24h
if [ -f "$STAMP" ]; then
  MTIME="$(stat -f %m "$STAMP" 2>/dev/null || stat -c %Y "$STAMP" 2>/dev/null || echo 0)"
  AGE=$(( $(date +%s) - MTIME ))
  [ "$AGE" -lt 86400 ] && exit 0
fi

# Mark now, then re-ingest the recent window fully detached so session start is never delayed.
# 35 days covers Claude Code's ~30-day purge plus slack; older history was captured at backfill.
RESCAN_DAYS="${CLAUDE_FOOTPRINT_RESCAN_DAYS:-35}"
touch "$STAMP" 2>/dev/null || true
( setsid bash "${SCRIPT_DIR}/ingest-tokscale.sh" --days "$RESCAN_DAYS" >/dev/null 2>&1 < /dev/null & ) >/dev/null 2>&1 || \
  ( bash "${SCRIPT_DIR}/ingest-tokscale.sh" --days "$RESCAN_DAYS" >/dev/null 2>&1 < /dev/null & ) >/dev/null 2>&1

exit 0
