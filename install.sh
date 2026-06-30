#!/usr/bin/env bash
set -euo pipefail

# install.sh — One-line installer for ai-footprint.
# Usage: curl -fsSL https://raw.githubusercontent.com/vinri2z/ai-footprint/main/install.sh | bash

# Override the install location with AI_FOOTPRINT_DIR.
INSTALL_DIR="${AI_FOOTPRINT_DIR:-$HOME/code/ai-footprint}"
SETTINGS_FILE="${HOME}/.claude/settings.json"

echo ""
echo "  ai-footprint installer"
echo "  Track the carbon and water footprint of all your AI coding agents."
echo ""

# 1. Check dependencies
for cmd in jq git; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is not installed." >&2
    if [[ "$(uname)" == "Darwin" ]]; then
      echo "  Install with: brew install $cmd" >&2
    else
      echo "  Install with: apt install $cmd" >&2
    fi
    exit 1
  fi
done

# 2. Clone or update (public repo — plain git, no auth needed)
REPO_URL="https://github.com/vinri2z/ai-footprint.git"
if [ -d "$INSTALL_DIR/.git" ]; then
  echo "Updating existing installation at $INSTALL_DIR..."
  git -C "$INSTALL_DIR" pull --ff-only --quiet
else
  echo "Cloning to $INSTALL_DIR..."
  mkdir -p "$(dirname "$INSTALL_DIR")"
  git clone --quiet "$REPO_URL" "$INSTALL_DIR"
fi

# 3. Run setup (checks deps, prints a summary). No database is created — reports read
#    straight from tokscale on demand.
echo ""
AI_FOOTPRINT_INSTALLER=1 bash "$INSTALL_DIR/scripts/setup.sh"

# 4. Configure Claude Code settings (status line only — there are no background hooks)
echo ""
echo "Configuring Claude Code..."

mkdir -p "${HOME}/.claude"

STATUSLINE_CMD="${INSTALL_DIR}/scripts/statusline.sh"

if [ -f "$SETTINGS_FILE" ]; then
  # Merge into existing settings
  EXISTING="$(cat "$SETTINGS_FILE")"

  # Add statusLine if not present
  HAS_STATUSLINE="$(echo "$EXISTING" | jq 'has("statusLine")' 2>/dev/null)" || HAS_STATUSLINE="false"
  if [ "$HAS_STATUSLINE" = "true" ]; then
    CURRENT_SL="$(echo "$EXISTING" | jq -r '.statusLine.command // ""' 2>/dev/null)"
    if echo "$CURRENT_SL" | grep -qE "ai-footprint|claude-(carbon|footprint)"; then
      echo "  statusLine: already configured (skipped)"
    else
      echo "  statusLine: skipped (already set to another tool)"
      echo "    To switch, replace the command in ~/.claude/settings.json with:"
      echo "    $STATUSLINE_CMD"
    fi
  else
    EXISTING="$(echo "$EXISTING" | jq --arg cmd "$STATUSLINE_CMD" '. + {statusLine: {type: "command", command: $cmd, refreshInterval: 1}}')"
    echo "  statusLine: added"
  fi

  echo "$EXISTING" | jq '.' > "$SETTINGS_FILE"
else
  # Create new settings file
  jq -n --arg sl "$STATUSLINE_CMD" '{
    statusLine: {type: "command", command: $sl, refreshInterval: 1}
  }' > "$SETTINGS_FILE"
  echo "  Created $SETTINGS_FILE"
fi

# 5. Install /footprint-report and /footprint-card slash commands
COMMANDS_DIR="${HOME}/.claude/commands"

mkdir -p "$COMMANDS_DIR"

# Remove the old carbon-* command links (renamed to footprint-*)
for OLD_NAME in carbon-report carbon-card; do
  OLD_LNK="${COMMANDS_DIR}/${OLD_NAME}.md"
  if [ -L "$OLD_LNK" ] || [ -f "$OLD_LNK" ]; then
    rm -f "$OLD_LNK"
    echo "  /${OLD_NAME}: removed (renamed to footprint-*)"
  fi
done

for SKILL_NAME in footprint-report footprint-card; do
  SKILL_SRC="${INSTALL_DIR}/skills/${SKILL_NAME}/SKILL.md"
  SKILL_LNK="${COMMANDS_DIR}/${SKILL_NAME}.md"
  if [ -L "$SKILL_LNK" ] || [ -f "$SKILL_LNK" ]; then
    echo "  /${SKILL_NAME}: already installed (skipped)"
  else
    ln -s "$SKILL_SRC" "$SKILL_LNK"
    echo "  /${SKILL_NAME}: installed"
  fi
done

echo ""
echo "Done. Restart Claude Code to see your CO2 and water in the status line."
echo ""
