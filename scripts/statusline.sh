#!/usr/bin/env bash
set -euo pipefail

# statusline.sh — Reads Claude Code status JSON from stdin, outputs formatted CO2 status line.
# Usage: echo '{"session_id":...}' | statusline.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FACTORS_FILE="${SCRIPT_DIR}/../data/factors.json"

# Read stdin
INPUT="$(cat)"

# Extract fields with defaults to avoid failures on null
MODEL_ID="$(echo "$INPUT" | jq -r '.model.id // ""')"
DISPLAY_NAME="$(echo "$INPUT" | jq -r '.model.display_name // "Unknown model"' | sed -E 's/ *\((1M|200K) context\)//')"
INPUT_TOKENS="$(echo "$INPUT" | jq -r '.context_window.total_input_tokens // 0')"
OUTPUT_TOKENS="$(echo "$INPUT" | jq -r '.context_window.total_output_tokens // 0')"
COST_USD="$(echo "$INPUT" | jq -r '.cost.total_cost_usd // 0')"
USED_PCT="$(echo "$INPUT" | jq -r '.context_window.used_percentage // 0')"
CURRENT_DIR="$(echo "$INPUT" | jq -r '.workspace.current_dir // ""')"

# Project name = last path segment
PROJECT="$(basename "$CURRENT_DIR")"

# Resolve model family
MODEL_FAMILY="sonnet"
if echo "$MODEL_ID" | grep -qiE "fable|mythos"; then
  MODEL_FAMILY="fable"
elif echo "$MODEL_ID" | grep -qi "opus"; then
  MODEL_FAMILY="opus"
elif echo "$MODEL_ID" | grep -qi "haiku"; then
  MODEL_FAMILY="haiku"
fi

# Load emission factors (zero for non-Anthropic models, e.g. local models
# behind ANTHROPIC_BASE_URL — a datacenter factor doesn't apply to them)
if echo "$MODEL_ID" | grep -qi "claude"; then
  FACTOR_IN="$(jq -r ".models.${MODEL_FAMILY}.input // 190" "$FACTORS_FILE")"
  FACTOR_OUT="$(jq -r ".models.${MODEL_FAMILY}.output // 1140" "$FACTORS_FILE")"
  WATER_IN="$(jq -r ".water_factors.${MODEL_FAMILY}.input // 2.198" "$FACTORS_FILE")"
  WATER_OUT="$(jq -r ".water_factors.${MODEL_FAMILY}.output // 13.187" "$FACTORS_FILE")"
else
  FACTOR_IN="0"
  FACTOR_OUT="0"
  WATER_IN="0"
  WATER_OUT="0"
fi

# Calculate CO2 in grams: (input * factor_in + output * factor_out) / 1_000_000
CO2_G="$(echo "$INPUT_TOKENS $FACTOR_IN $OUTPUT_TOKENS $FACTOR_OUT" | LC_ALL=C awk '{printf "%.0f", ($1 * $2 + $3 * $4) / 1000000}')"

# Calculate water in liters: (input * water_in + output * water_out) / 1_000_000
WATER_L="$(echo "$INPUT_TOKENS $WATER_IN $OUTPUT_TOKENS $WATER_OUT" | LC_ALL=C awk '{printf "%.4f", ($1 * $2 + $3 * $4) / 1000000}')"

# Format CO2 with adaptive unit
if [ "$CO2_G" -ge 1000 ] 2>/dev/null; then
  CO2_DISPLAY="$(echo "$CO2_G" | LC_ALL=C awk '{printf "%.1fkg", $1/1000}') CO₂"
else
  CO2_DISPLAY="${CO2_G}g CO₂"
fi

# Format water with adaptive unit (mL under 1 L, else L)
WATER_DISPLAY="$(echo "$WATER_L" | LC_ALL=C awk '{ if ($1 >= 1) printf "%.1fL", $1; else printf "%.0fmL", $1*1000 }')"

# Round cost to 2 decimals
COST_DISPLAY="$(echo "$COST_USD" | LC_ALL=C awk '{printf "%.2f", $1}')"

# Time-based animation: frame index derived from epoch second, so emoji changes
# exactly once per second regardless of statusline refresh cadence.
# CO2 runs tree → log → fire → smoke; water runs ice → splash → droplet → vapor.
CO2_FRAMES=(🌳 🪵 🔥 💨)
WATER_FRAMES=(🧊 💦 💧 💨)

IDX=$(( $(date +%s) % 4 ))

CO2_EMOJI="${CO2_FRAMES[$IDX]}"
WATER_EMOJI="${WATER_FRAMES[$IDX]}"

# Build progress bar (10 blocks)
FILLED=$(( USED_PCT * 10 / 100 ))
EMPTY=$(( 10 - FILLED ))
PROGRESS_BAR=""
for ((i=0; i<FILLED; i++)); do PROGRESS_BAR="${PROGRESS_BAR}▓"; done
for ((i=0; i<EMPTY; i++)); do PROGRESS_BAR="${PROGRESS_BAR}░"; done

# Color dot and percentage display
if [ "$USED_PCT" -ge 80 ]; then
  DOT="🔴"
  PCT_DISPLAY="COMPACT!"
elif [ "$USED_PCT" -ge 60 ]; then
  DOT="🟡"
  PCT_DISPLAY="${USED_PCT}%"
else
  DOT="🟢"
  PCT_DISPLAY="${USED_PCT}%"
fi

# 5-hour block usage via stdin (preferred) or Anthropic OAuth API (fallback).
# Canonical source: same data as `/usage` in Claude Code. Replaces ccusage heuristic.
USAGE_SEGMENT=""
if command -v jq &>/dev/null; then
  FIVE_PCT=""
  FIVE_RESET_ISO=""

  # Priority 1: Claude Code injects rate_limits in the statusline stdin JSON.
  FIVE_PCT="$(echo "$INPUT" | jq -r '.rate_limits.five_hour.used_percentage // empty')"
  FIVE_RESET_ISO="$(echo "$INPUT" | jq -r '.rate_limits.five_hour.resets_at // empty')"

  # Priority 2: fallback to GET /api/oauth/usage with 60s cache.
  if [ -z "$FIVE_PCT" ]; then
    USAGE_CACHE_DIR="${HOME}/.claude/ai-footprint"
    USAGE_CACHE_FILE="${USAGE_CACHE_DIR}/oauth-usage.json"
    USAGE_CACHE_TTL=60
    mkdir -p "$USAGE_CACHE_DIR"

    NEEDS_REFRESH=1
    if [ -f "$USAGE_CACHE_FILE" ]; then
      CACHE_MTIME="$(stat -f %m "$USAGE_CACHE_FILE" 2>/dev/null || stat -c %Y "$USAGE_CACHE_FILE" 2>/dev/null || echo 0)"
      CACHE_AGE=$(( $(date +%s) - CACHE_MTIME ))
      [ "$CACHE_AGE" -lt "$USAGE_CACHE_TTL" ] && NEEDS_REFRESH=0
    fi

    if [ "$NEEDS_REFRESH" = "1" ]; then
      TOKEN=""
      if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
        TOKEN="$CLAUDE_CODE_OAUTH_TOKEN"
      elif command -v security &>/dev/null; then
        BLOB="$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)"
        [ -n "$BLOB" ] && TOKEN="$(echo "$BLOB" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)"
      fi
      if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
        CREDS="${HOME}/.claude/.credentials.json"
        [ -f "$CREDS" ] && TOKEN="$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDS" 2>/dev/null)"
      fi

      if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
        RESPONSE="$(curl -s --max-time 5 \
          -H "Accept: application/json" \
          -H "Content-Type: application/json" \
          -H "Authorization: Bearer $TOKEN" \
          -H "anthropic-beta: oauth-2025-04-20" \
          -H "User-Agent: claude-code/2.1.34" \
          "https://api.anthropic.com/api/oauth/usage" 2>/dev/null || true)"
        if [ -n "$RESPONSE" ] && echo "$RESPONSE" | jq -e '.five_hour' >/dev/null 2>&1; then
          echo "$RESPONSE" > "$USAGE_CACHE_FILE"
        fi
      fi
    fi

    if [ -f "$USAGE_CACHE_FILE" ]; then
      FIVE_PCT="$(jq -r '.five_hour.utilization // empty' "$USAGE_CACHE_FILE" 2>/dev/null)"
      FIVE_RESET_ISO="$(jq -r '.five_hour.resets_at // empty' "$USAGE_CACHE_FILE" 2>/dev/null)"
    fi
  fi

  if [ -n "$FIVE_PCT" ]; then
    USAGE_PCT_INT="$(echo "$FIVE_PCT" | LC_ALL=C awk '{printf "%.0f", $1}')"
    [ "$USAGE_PCT_INT" -gt 100 ] 2>/dev/null && USAGE_PCT_INT=100

    END_EPOCH=""
    RESET_LOCAL=""
    if [ -n "$FIVE_RESET_ISO" ]; then
      # Claude Code stdin passes resets_at as epoch (number); API returns ISO-8601 with fractional
      # seconds + tz offset (e.g. 2026-04-21T08:00:00.608966+00:00). Handle both.
      if [[ "$FIVE_RESET_ISO" =~ ^[0-9]+$ ]]; then
        END_EPOCH="$FIVE_RESET_ISO"
      else
        ISO_TRIM="${FIVE_RESET_ISO%%.*}"     # strip fractional seconds
        ISO_TRIM="${ISO_TRIM%%Z}"            # strip trailing Z
        ISO_TRIM="${ISO_TRIM%%+*}"           # strip +HH:MM offset
        END_EPOCH="$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "$ISO_TRIM" "+%s" 2>/dev/null \
          || date -d "$FIVE_RESET_ISO" "+%s" 2>/dev/null || echo "")"
      fi
      if [ -n "$END_EPOCH" ]; then
        RESET_LOCAL="$(date -r "$END_EPOCH" "+%H:%M" 2>/dev/null \
          || date -d "@$END_EPOCH" "+%H:%M" 2>/dev/null || echo "")"
      fi
    fi

    # 🔥 when sustained burn rate over elapsed time would finish the 5h block
    # above 100% of the limit. 15 min grace + 15% floor to absorb bursty starts.
    # Block start derived as end - 5h (18000s).
    WARN=""
    if [ -n "$END_EPOCH" ] && [ "$USAGE_PCT_INT" -ge 15 ] 2>/dev/null; then
      NOW_EPOCH="$(date +%s)"
      START_EPOCH=$(( END_EPOCH - 18000 ))
      ELAPSED_SEC=$(( NOW_EPOCH - START_EPOCH ))
      if [ "$ELAPSED_SEC" -gt 900 ]; then
        HOT="$(echo "$FIVE_PCT $ELAPSED_SEC" | LC_ALL=C awk '{print (($1 * 18000 / $2) >= 100) ? "1" : "0"}')"
        [ "$HOT" = "1" ] && WARN="🔥 "
      fi
    fi

    if [ -n "$RESET_LOCAL" ]; then
      USAGE_SEGMENT="${WARN}Use ${USAGE_PCT_INT}% ↻${RESET_LOCAL}"
    else
      USAGE_SEGMENT="${WARN}Use ${USAGE_PCT_INT}%"
    fi
  fi
fi

# Git branch (if in a git repo)
BRANCH_SUFFIX=""
if [ -n "$CURRENT_DIR" ] && command -v git &>/dev/null; then
  BRANCH="$(git -C "$CURRENT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  [ -n "$BRANCH" ] && [ "$BRANCH" != "HEAD" ] && BRANCH_SUFFIX=" ⌥ ${BRANCH}"
fi

# Assemble the pipe-delimited groups, dropping any that are empty.
SEGMENTS=(
  "${PROJECT}${BRANCH_SUFFIX}"
  "${DOT} ${DISPLAY_NAME} ${PROGRESS_BAR} ${PCT_DISPLAY}"
  "${CO2_EMOJI} ${CO2_DISPLAY} · ${WATER_EMOJI} ${WATER_DISPLAY} · \$${COST_DISPLAY}"
)
[ -n "$USAGE_SEGMENT" ] && SEGMENTS+=("$USAGE_SEGMENT")

SEP=" | "
COLS="${COLUMNS:-0}"

# Display width in terminal columns. Claude Code pipes our stdout, so tput/stty
# can't read the real width — and we only know it via $COLUMNS (CC v2.1.153+).
# Decode UTF-8 from bytes under LC_ALL=C (locale-independent): every code point
# is 1 column except the status/fire emoji (cp >= 0x1F000), which are 2 wide.
disp_width() {
  printf '%s' "$1" | LC_ALL=C awk '
    BEGIN { for (n = 0; n < 256; n++) ord[sprintf("%c", n)] = n; w = 0 }
    {
      s = $0; L = length(s); i = 1
      while (i <= L) {
        b = ord[substr(s, i, 1)]
        if      (b < 128) { cp = b;         len = 1 }
        else if (b < 224) { cp = b - 192;   len = 2 }
        else if (b < 240) { cp = b - 224;   len = 3 }
        else              { cp = b - 240;   len = 4 }
        for (j = 1; j < len; j++) cp = cp * 64 + (ord[substr(s, i + j, 1)] - 128)
        w += (cp >= 126976) ? 2 : 1
        i += len
      }
    }
    END { print w }'
}

if [ "$COLS" -le 0 ] 2>/dev/null; then
  # Width unknown (older Claude Code): keep the original single-line output.
  ( IFS=; first=1; out=""
    for seg in "${SEGMENTS[@]}"; do
      if [ "$first" = 1 ]; then out="$seg"; first=0; else out="${out}${SEP}${seg}"; fi
    done
    printf '%s\n' "$out" )
else
  # Greedily pack groups into rows up to $COLS; wrap (no separator) when a group
  # would overflow. A lone oversized group is printed as-is — never truncated.
  line=""
  for seg in "${SEGMENTS[@]}"; do
    if [ -z "$line" ]; then
      cand="$seg"
    else
      cand="${line}${SEP}${seg}"
    fi
    if [ -z "$line" ] || [ "$(disp_width "$cand")" -le "$COLS" ]; then
      line="$cand"
    else
      printf '%s\n' "$line"
      line="$seg"
    fi
  done
  printf '%s\n' "$line"
fi
