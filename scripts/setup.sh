#!/usr/bin/env bash
set -euo pipefail

# setup.sh — Initialize ai-footprint: check dependencies and show a quick footprint summary.
#
# There is no database to create: ai-footprint reads usage straight from tokscale on every
# report run (see scripts/footprint-data.sh), so setup only verifies the toolchain and prints
# a one-shot summary so you can see numbers immediately.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
CACHE_DIR="${HOME}/.claude/ai-footprint"

echo "🌿 ai-footprint setup"
echo "─────────────────────────────"

# 1. Check dependencies
echo "Checking dependencies..."

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is not installed. Install with: brew install jq" >&2
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
echo "  python3: OK"
echo "  npx: OK"

# 2. Create cache directory (used by the status line for the 5h OAuth usage cache)
mkdir -p "$CACHE_DIR"

# 3. One-shot summary straight from tokscale (full history)
echo ""
echo "Reading multi-agent usage from tokscale (first run may take a moment)..."
DATA_JSON="$(bash "${SCRIPT_DIR}/footprint-data.sh" --all 2>/dev/null || true)"

echo ""
echo "─────────────────────────────"
echo "Summary:"

if [ -n "$DATA_JSON" ]; then
  TOTAL_CO2_G="$(printf '%s' "$DATA_JSON" | jq -r '.all.co2' | LC_ALL=C awk '{printf "%.0f", $1}')"
  TOTAL_WATER_L="$(printf '%s' "$DATA_JSON" | jq -r '.all.water' | LC_ALL=C awk '{printf "%.1f", $1}')"
  YEAR_CO2_G="$(printf '%s' "$DATA_JSON" | jq -r '.year.co2' | LC_ALL=C awk '{printf "%.0f", $1}')"
  AGENTS="$(printf '%s' "$DATA_JSON" | jq -r '.all.agents')"
  CURRENT_YEAR="$(date +%Y)"

  if [ "$TOTAL_CO2_G" -ge 1000 ] 2>/dev/null; then
    TOTAL_CO2_DISPLAY="$(echo "$TOTAL_CO2_G" | LC_ALL=C awk '{printf "%.1fkg", $1/1000}')"
  else
    TOTAL_CO2_DISPLAY="${TOTAL_CO2_G}g"
  fi
  if [ "$YEAR_CO2_G" -ge 1000 ] 2>/dev/null; then
    YEAR_CO2_DISPLAY="$(echo "$YEAR_CO2_G" | LC_ALL=C awk '{printf "%.1fkg", $1/1000}')"
  else
    YEAR_CO2_DISPLAY="${YEAR_CO2_G}g"
  fi

  echo "  Agents tracked    : ${AGENTS}"
  echo "  Total CO2         : ${TOTAL_CO2_DISPLAY} CO2"
  echo "  Total water       : ${TOTAL_WATER_L} L"
  echo "  CO2 (${CURRENT_YEAR})       : ${YEAR_CO2_DISPLAY} CO2"
else
  echo "  No usage found yet (or tokscale could not run). Reports will populate once you"
  echo "  have agent activity on disk."
fi

# 4. Next steps (skip if called from install.sh which handles config automatically)
if [ "${AI_FOOTPRINT_INSTALLER:-}" != "1" ]; then
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
  }
}
EOF
  echo ""
  echo "2. Reload Claude Code to pick up the new status line."
fi
echo ""
echo "Setup complete."
