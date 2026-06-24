#!/usr/bin/env bash
set -euo pipefail

# setup.sh — Initialize ai-footprint: check deps, create DB, backfill history, show summary.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
# Data dir/DB kept as claude-carbon for backward compatibility with existing installs.
DB_DIR="${HOME}/.claude/claude-carbon"
DB_PATH="${DB_DIR}/carbon.db"

echo "🌿 ai-footprint setup"
echo "─────────────────────────────"

# 1. Check dependencies
echo "Checking dependencies..."

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is not installed. Install with: brew install jq" >&2
  exit 1
fi

if ! command -v sqlite3 &>/dev/null; then
  echo "ERROR: sqlite3 is not installed. Install with: brew install sqlite3" >&2
  exit 1
fi

if ! command -v python3 &>/dev/null; then
  echo "ERROR: python3 is not installed (needed for date math + reports)." >&2
  exit 1
fi

# tokscale is the token-usage source for all agents. Resolved lazily via npx (needs Node).
if ! command -v npx &>/dev/null; then
  echo "ERROR: npx (Node.js) is not installed. tokscale runs via 'npx tokscale@latest'." >&2
  echo "       Install Node from https://nodejs.org or 'brew install node'." >&2
  exit 1
fi

echo "  jq: OK"
echo "  sqlite3: OK"
echo "  python3: OK"
echo "  npx: OK"

# 2. Create directory
echo ""
echo "Creating database directory at ${DB_DIR}..."
mkdir -p "$DB_DIR"

# 3. Create SQLite database with schema
echo "Initializing database at ${DB_PATH}..."
sqlite3 "$DB_PATH" <<'SQL'
CREATE TABLE IF NOT EXISTS sessions (
  session_id TEXT PRIMARY KEY,
  project TEXT,
  model TEXT,
  input_tokens INTEGER,
  output_tokens INTEGER,
  cache_read_tokens INTEGER DEFAULT 0,
  cache_creation_tokens INTEGER DEFAULT 0,
  cost_usd REAL,
  co2_grams REAL,
  water_liters REAL,
  started_at TEXT,
  ended_at TEXT,
  source TEXT DEFAULT 'live',
  methodology_version INTEGER DEFAULT 1,
  excluded INTEGER DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_sessions_year ON sessions(started_at);

-- usage: multi-agent token usage, sourced from tokscale. One row per
-- (date, client, provider, model). Raw token columns kept so recompute.sh can
-- re-derive co2/water after a factors.json change. Replaces `sessions` as the
-- table reports read from; `sessions` is retained read-only for legacy installs.
CREATE TABLE IF NOT EXISTS usage (
  date TEXT,
  client TEXT,
  provider TEXT,
  model TEXT,
  family TEXT,
  input_tokens INTEGER DEFAULT 0,
  output_tokens INTEGER DEFAULT 0,
  cache_read_tokens INTEGER DEFAULT 0,
  cache_write_tokens INTEGER DEFAULT 0,
  co2_grams REAL,
  water_liters REAL,
  cost_usd REAL,
  excluded INTEGER DEFAULT 0,
  methodology_version INTEGER DEFAULT 2,
  source TEXT DEFAULT 'tokscale',
  updated_at TEXT,
  PRIMARY KEY (date, client, provider, model)
);
CREATE INDEX IF NOT EXISTS idx_usage_date ON usage(date);
CREATE INDEX IF NOT EXISTS idx_usage_client ON usage(client);
CREATE INDEX IF NOT EXISTS idx_usage_provider ON usage(provider);
SQL

# Migrate pre-existing DBs that lack the newer columns (idempotent; errors ignored when present).
sqlite3 "$DB_PATH" "ALTER TABLE sessions ADD COLUMN cache_read_tokens INTEGER DEFAULT 0;" 2>/dev/null || true
sqlite3 "$DB_PATH" "ALTER TABLE sessions ADD COLUMN cache_creation_tokens INTEGER DEFAULT 0;" 2>/dev/null || true
sqlite3 "$DB_PATH" "ALTER TABLE sessions ADD COLUMN methodology_version INTEGER DEFAULT 1;" 2>/dev/null || true
sqlite3 "$DB_PATH" "ALTER TABLE sessions ADD COLUMN excluded INTEGER DEFAULT 0;" 2>/dev/null || true
sqlite3 "$DB_PATH" "ALTER TABLE sessions ADD COLUMN water_liters REAL;" 2>/dev/null || true

echo "  Schema created."

# 4. Run backfill via tokscale (all agents, full available history)
echo ""
echo "Backfilling multi-agent usage from tokscale (first run may take a few minutes)..."
bash "${SCRIPT_DIR}/ingest-tokscale.sh"

# 5. Show summary
echo ""
echo "─────────────────────────────"
echo "Summary:"

TOTAL_SESSIONS="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM usage WHERE COALESCE(excluded,0)=0;")"
TOTAL_CO2_G="$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(co2_grams), 0) FROM usage;" | LC_ALL=C awk '{printf "%.0f", $1}')"
TOTAL_WATER_L="$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(water_liters), 0) FROM usage;" | LC_ALL=C awk '{printf "%.1f", $1}')"
CURRENT_YEAR="$(date +%Y)"
YEAR_CO2_G="$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(co2_grams), 0) FROM usage WHERE date LIKE '${CURRENT_YEAR}%';" | LC_ALL=C awk '{printf "%.0f", $1}')"

# Adaptive CO2 units for total
if [ "$TOTAL_CO2_G" -ge 1000 ] 2>/dev/null; then
  TOTAL_CO2_DISPLAY="$(echo "$TOTAL_CO2_G" | LC_ALL=C awk '{printf "%.1fkg", $1/1000}')"
else
  TOTAL_CO2_DISPLAY="${TOTAL_CO2_G}g"
fi

# Adaptive CO2 units for year
if [ "$YEAR_CO2_G" -ge 1000 ] 2>/dev/null; then
  YEAR_CO2_DISPLAY="$(echo "$YEAR_CO2_G" | LC_ALL=C awk '{printf "%.1fkg", $1/1000}')"
else
  YEAR_CO2_DISPLAY="${YEAR_CO2_G}g"
fi

echo "  Usage rows        : ${TOTAL_SESSIONS}"
echo "  Total CO2         : ${TOTAL_CO2_DISPLAY} CO2"
echo "  Total water       : ${TOTAL_WATER_L} L"
echo "  CO2 (${CURRENT_YEAR})       : ${YEAR_CO2_DISPLAY} CO2"

# 6. Next steps (skip if called from install.sh which handles config automatically)
if [ "${CLAUDE_CARBON_INSTALLER:-}" != "1" ]; then
  echo ""
  echo "─────────────────────────────"
  echo "Next steps:"
  echo ""
  echo "1. Add to ~/.claude/settings.json:"
  echo ""
  cat <<EOF
{
  "statusLine": {
    "type": "command",
    "command": "${PLUGIN_DIR}/scripts/statusline.sh"
  },
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "${PLUGIN_DIR}/scripts/persist-session.sh"
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "${PLUGIN_DIR}/scripts/safety-rescan.sh"
          }
        ]
      }
    ]
  }
}
EOF
  echo ""
  echo "2. Reload Claude Code to pick up the new status line."
fi
echo ""
echo "Setup complete."
