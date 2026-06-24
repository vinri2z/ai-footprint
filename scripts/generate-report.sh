#!/usr/bin/env bash
# generate-report.sh — Generate Claude Footprint Report PNGs (CO2 + water) from DB stats.
# Usage: generate-report.sh [--since YYYY-MM-DD] [--all]
# Default: since January 1st of current year. Output is English only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_DIR="$PROJECT_DIR/templates"
EXPORT_DIR="$PROJECT_DIR/exports"
DB_PATH="${CLAUDE_CARBON_DB:-${HOME}/.claude/claude-carbon/carbon.db}"
TODAY="$(date +%Y-%m-%d)"
YEAR="$(date +%Y)"

# ── Parse args ──────────────────────────────────────────────
SINCE="${YEAR}-01-01"
SINCE_LABEL="January ${YEAR}"
LABEL_AUTO=1   # default mode: derive the "since" label from the earliest real session

# Full month names for the auto-derived label (index 1-12)
MONTHS_EN=("" "January" "February" "March" "April" "May" "June" "July" "August" "September" "October" "November" "December")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)
      SINCE="$2"
      SINCE_LABEL="$2"
      LABEL_AUTO=0
      shift 2
      ;;
    --all)
      SINCE=""
      SINCE_LABEL="the beginning"
      LABEL_AUTO=0
      shift
      ;;
    *)
      echo "Usage: generate-report.sh [--since YYYY-MM-DD] [--all]" >&2
      exit 1
      ;;
  esac
done

# Build SQL WHERE clause (always filters out excluded rows, e.g. <synthetic>)
if [ -n "$SINCE" ]; then
  WHERE="WHERE COALESCE(excluded, 0) = 0 AND date >= '${SINCE}'"
else
  WHERE="WHERE COALESCE(excluded, 0) = 0"
fi

# ── Deps check ──────────────────────────────────────────────
for cmd in sqlite3 node; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: $cmd is required but not found." >&2
    exit 1
  fi
done

if [ ! -f "$DB_PATH" ]; then
  echo "Error: carbon.db not found. Run setup.sh first." >&2
  exit 1
fi

mkdir -p "$EXPORT_DIR"

if ! sqlite3 "$DB_PATH" "SELECT 1 FROM usage LIMIT 1;" >/dev/null 2>&1; then
  echo "Error: no multi-agent usage yet. Run: bash scripts/ingest-tokscale.sh" >&2
  exit 1
fi

# ── Query DB (usage table; one row per date/client/provider/model) ──────────
echo "Querying carbon.db (since ${SINCE_LABEL})..."

# TOTAL_AGENTS = distinct tokscale clients (Claude Code, Codex, Cursor, ...)
read -r TOTAL_AGENTS TOTAL_CO2_RAW TOTAL_COST_RAW FIRST_DATE_RAW <<< \
  "$(sqlite3 "$DB_PATH" "SELECT COUNT(DISTINCT client), COALESCE(SUM(co2_grams), 0), COALESCE(SUM(cost_usd), 0), COALESCE(MIN(date), '') FROM usage ${WHERE};" | tr '|' ' ')"

TOTAL_WATER_RAW="$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(water_liters), 0) FROM usage ${WHERE};")"

# Top 5 agents (tokscale client) with their distinct-model count
TOP_PROJECTS="$(sqlite3 -separator '|' "$DB_PATH" "SELECT client, SUM(co2_grams), COUNT(DISTINCT model) FROM usage ${WHERE} GROUP BY client ORDER BY SUM(co2_grams) DESC LIMIT 5;")"

TOP_MODEL="$(sqlite3 "$DB_PATH" "SELECT model FROM usage ${WHERE} GROUP BY model ORDER BY SUM(co2_grams) DESC LIMIT 1;")"

# Total tokens
TOTAL_TOKENS_RAW="$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(input_tokens), 0) + COALESCE(SUM(output_tokens), 0) FROM usage ${WHERE};")"

# ── Format values ───────────────────────────────────────────
format_co2() {
  local grams="$1"
  if (( $(echo "$grams >= 1000" | LC_ALL=C bc -l) )); then
    echo "$(echo "$grams" | LC_ALL=C awk '{printf "%.1f", $1/1000}') kg"
  else
    echo "$(echo "$grams" | LC_ALL=C awk '{printf "%.0f", $1}') g"
  fi
}

read -r TOTAL_CO2_VALUE TOTAL_CO2_UNIT <<< "$(format_co2 "$TOTAL_CO2_RAW")"
TOTAL_COST="$(echo "$TOTAL_COST_RAW" | LC_ALL=C awk '{printf "%.0f", $1}')"
FIRST_DATE="$(echo "$FIRST_DATE_RAW" | cut -c1-10)"
EQUIV_KM="$(echo "$TOTAL_CO2_RAW" | LC_ALL=C awk '{printf "%.1f", $1/120}')"

# Water: adaptive value/unit (L, or m³ above 1000 L), plus equivalences
format_water() {
  local liters="$1"
  if (( $(echo "$liters >= 1000" | LC_ALL=C bc -l) )); then
    echo "$(echo "$liters" | LC_ALL=C awk '{printf "%.1f", $1/1000}') m³"
  else
    echo "$(echo "$liters" | LC_ALL=C awk '{printf "%.0f", $1}') L"
  fi
}
read -r TOTAL_WATER_VALUE TOTAL_WATER_UNIT <<< "$(format_water "$TOTAL_WATER_RAW")"
EQUIV_SHOWERS="$(echo "$TOTAL_WATER_RAW" | LC_ALL=C awk '{printf "%.1f", $1/65}')"
EQUIV_BOTTLES="$(echo "$TOTAL_WATER_RAW" | LC_ALL=C awk '{printf "%.0f", $1/0.5}')"

# In default mode, label the report with the actual earliest session month, not Jan 1st
# (transcripts older than ~30 days are purged, so the real data rarely starts in January).
if [ "$LABEL_AUTO" = "1" ] && [ -n "$FIRST_DATE" ]; then
  _lm="$(echo "$FIRST_DATE" | cut -c6-7 | sed 's/^0//')"
  _ly="$(echo "$FIRST_DATE" | cut -c1-4)"
  if [ -n "$_lm" ] && [ "$_lm" -ge 1 ] 2>/dev/null && [ "$_lm" -le 12 ] 2>/dev/null; then
    SINCE_LABEL="${MONTHS_EN[$_lm]} ${_ly}"
  fi
fi

# Format tokens (M)
TOTAL_TOKENS="$(echo "$TOTAL_TOKENS_RAW" | LC_ALL=C awk '{printf "%.0f", $1/1000000}')"

# Projection annuelle (fourchette)
# Use actual first session date, not --since filter
ACTUAL_FIRST="$(echo "$FIRST_DATE" | cut -c1-10)"
_FIRST_EPOCH="$(date -j -f "%Y-%m-%d" "${ACTUAL_FIRST}" +%s 2>/dev/null || date -d "${ACTUAL_FIRST}" +%s 2>/dev/null || echo "")"
if [ -n "$_FIRST_EPOCH" ]; then
  DAYS_ELAPSED="$(( ( $(date +%s) - _FIRST_EPOCH ) / 86400 ))"
else
  DAYS_ELAPSED=0
fi
if [ "$DAYS_ELAPSED" -gt 0 ]; then
  # Linear: average daily rate extrapolated (in tCO2 with 1 decimal)
  PROJ_LINEAR="$(echo "$TOTAL_CO2_RAW $DAYS_ELAPSED" | LC_ALL=C awk '{printf "%.1f", ($1 / $2) * 365 / 1000000}')"

  # Trend: last 30 days daily rate extrapolated
  if [ -n "$WHERE" ]; then
    LAST_MONTH_DATA="$(sqlite3 "$DB_PATH" "SELECT SUM(co2_grams), MIN(date), MAX(date) FROM usage ${WHERE} AND date >= date('now', '-30 days');" | tr '|' ' ')"
  else
    LAST_MONTH_DATA="$(sqlite3 "$DB_PATH" "SELECT SUM(co2_grams), MIN(date), MAX(date) FROM usage WHERE date >= date('now', '-30 days');" | tr '|' ' ')"
  fi
  LAST_MONTH_CO2="$(echo "$LAST_MONTH_DATA" | LC_ALL=C awk '{print $1}')"
  LAST_MONTH_START="$(echo "$LAST_MONTH_DATA" | LC_ALL=C awk '{print $2}' | cut -c1-10)"
  LAST_MONTH_END="$(echo "$LAST_MONTH_DATA" | LC_ALL=C awk '{print $3}' | cut -c1-10)"
  LAST_MONTH_DAYS="$(( ( $(date -j -f "%Y-%m-%d" "${LAST_MONTH_END}" +%s 2>/dev/null || date -d "${LAST_MONTH_END}" +%s 2>/dev/null) - $(date -j -f "%Y-%m-%d" "${LAST_MONTH_START}" +%s 2>/dev/null || date -d "${LAST_MONTH_START}" +%s 2>/dev/null) ) / 86400 ))"
  if [ "$LAST_MONTH_DAYS" -gt 0 ]; then
    PROJ_TREND="$(echo "$LAST_MONTH_CO2 $LAST_MONTH_DAYS" | LC_ALL=C awk '{printf "%.1f", ($1 / $2) * 365 / 1000000}')"
  else
    PROJ_TREND="$PROJ_LINEAR"
  fi

  # Sort low-high for display (compare as floats)
  LOW="$(echo "$PROJ_LINEAR $PROJ_TREND" | LC_ALL=C awk '{if ($1 <= $2) print $1; else print $2}')"
  HIGH="$(echo "$PROJ_LINEAR $PROJ_TREND" | LC_ALL=C awk '{if ($1 >= $2) print $1; else print $2}')"
  PROJECTION="${LOW} - ${HIGH}"
else
  PROJECTION="0"
fi

# Format model: strip provider/region prefixes and the claude- prefix for a short label
TOP_MODEL_DISPLAY="$(echo "$TOP_MODEL" | sed 's/^[a-z_]*\.//; s/^anthropic\.//; s/^eu\.anthropic\.//; s/claude-//; s/-4-6//; s/-4-5.*//')"

# ── Monthly bars data (injected into HTML by python below) ──
MONTHLY_DATA="$(sqlite3 -separator '|' "$DB_PATH" "SELECT substr(date, 1, 7), SUM(co2_grams) FROM usage ${WHERE} GROUP BY substr(date, 1, 7) ORDER BY substr(date, 1, 7);")"

# ── Parse top 5 agents (P_SESSIONS now holds the distinct-model count) ──────
declare -a P_NAME P_CO2 P_SESSIONS
i=0
while IFS='|' read -r pname pco2 psessions; do
  [ -z "$pname" ] && continue
  P_NAME[$i]="$pname"
  P_CO2[$i]="$(format_co2 "$pco2")"
  P_SESSIONS[$i]="$psessions"
  i=$((i+1))
done <<< "$TOP_PROJECTS"

for ((j=i; j<5; j++)); do
  P_NAME[$j]="-"
  P_CO2[$j]="-"
  P_SESSIONS[$j]="0"
done

# ── Generate HTML files ─────────────────────────────────────
echo "Generating HTML variants..."

inject_common() {
  local src="$1" dst="$2"
  sed \
    -e "s|{{TODAY}}|${TODAY}|g" \
    -e "s|{{SINCE_LABEL}}|${SINCE_LABEL}|g" \
    -e "s|{{TOTAL_CO2_VALUE}}|${TOTAL_CO2_VALUE}|g" \
    -e "s|{{TOTAL_CO2_UNIT}}|${TOTAL_CO2_UNIT}|g" \
    -e "s|{{TOTAL_WATER_VALUE}}|${TOTAL_WATER_VALUE}|g" \
    -e "s|{{TOTAL_WATER_UNIT}}|${TOTAL_WATER_UNIT}|g" \
    -e "s|{{EQUIV_SHOWERS}}|${EQUIV_SHOWERS}|g" \
    -e "s|{{EQUIV_BOTTLES}}|${EQUIV_BOTTLES}|g" \
    -e "s|{{TOTAL_AGENTS}}|${TOTAL_AGENTS}|g" \
    -e "s|{{FIRST_DATE}}|${FIRST_DATE}|g" \
    -e "s|{{TOTAL_COST}}|${TOTAL_COST}|g" \
    -e "s|{{EQUIV_KM}}|${EQUIV_KM}|g" \
    -e "s|{{TOP_MODEL}}|${TOP_MODEL_DISPLAY}|g" \
    -e "s|{{TOTAL_TOKENS}}|${TOTAL_TOKENS}|g" \
    -e "s|{{PROJECTION}}|${PROJECTION}|g" \
    -e "s|{{P1_NAME}}|${P_NAME[0]}|g" \
    -e "s|{{P1_CO2}}|${P_CO2[0]}|g" \
    -e "s|{{P1_SESSIONS}}|${P_SESSIONS[0]}|g" \
    -e "s|{{P2_NAME}}|${P_NAME[1]}|g" \
    -e "s|{{P2_CO2}}|${P_CO2[1]}|g" \
    -e "s|{{P2_SESSIONS}}|${P_SESSIONS[1]}|g" \
    -e "s|{{P3_NAME}}|${P_NAME[2]}|g" \
    -e "s|{{P3_CO2}}|${P_CO2[2]}|g" \
    -e "s|{{P3_SESSIONS}}|${P_SESSIONS[2]}|g" \
    -e "s|{{P4_NAME}}|${P_NAME[3]}|g" \
    -e "s|{{P4_CO2}}|${P_CO2[3]}|g" \
    -e "s|{{P4_SESSIONS}}|${P_SESSIONS[3]}|g" \
    -e "s|{{P5_NAME}}|${P_NAME[4]}|g" \
    -e "s|{{P5_CO2}}|${P_CO2[4]}|g" \
    -e "s|{{P5_SESSIONS}}|${P_SESSIONS[4]}|g" \
    "$src" > "$dst"
}

# Generate templates (English only)
_t=$(mktemp /tmp/claude-footprint-summary-XXXXXX); TMP_SUMMARY="${_t}.html"; mv "$_t" "$TMP_SUMMARY"
_t=$(mktemp /tmp/claude-footprint-detailed-XXXXXX); TMP_DETAILED="${_t}.html"; mv "$_t" "$TMP_DETAILED"
inject_common "$TEMPLATE_DIR/report-summary.html" "$TMP_SUMMARY"
inject_common "$TEMPLATE_DIR/report-detailed.html" "$TMP_DETAILED"

# Inject monthly bars via python (bash/sed can't handle % in style attrs)
_t=$(mktemp /tmp/claude-footprint-monthly-XXXXXX); TMP_MONTHLY="${_t}.txt"; mv "$_t" "$TMP_MONTHLY"
echo "$MONTHLY_DATA" > "$TMP_MONTHLY"

export TMP_SUMMARY TMP_MONTHLY
python3 << 'PYEOF'
import sys, os

months_en = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
summary_file = os.environ["TMP_SUMMARY"]
monthly_file = os.environ["TMP_MONTHLY"]

# Parse monthly data
rows = []
with open(monthly_file) as f:
    for line in f:
        line = line.strip()
        if not line or "|" not in line:
            continue
        month_key, co2_str = line.split("|", 1)
        co2 = float(co2_str)
        month_num = int(month_key.split("-")[1])
        label = months_en[month_num - 1]
        if co2 >= 1000:
            display = f"{co2/1000:.1f} kg"
        else:
            display = f"{co2:.0f} g"
        rows.append((label, co2, display))

# Calculate percentages
max_co2 = max(r[1] for r in rows) if rows else 1
bars_html = ""
for label, co2, display in rows:
    pct = int(round(co2 / max_co2 * 100))
    bars_html += (
        f'<div class="bar-row">'
        f'<span class="bar-label">{label}</span>'
        f'<div class="bar-track"><div class="bar-fill" style="width: {pct}%"></div></div>'
        f'<span class="bar-value">{display}</span>'
        f'</div>\n'
    )

# Inject into the summary file
if summary_file and os.path.exists(summary_file):
    with open(summary_file) as f:
        content = f.read()
    content = content.replace("{{MONTHLY_BARS}}", bars_html)
    with open(summary_file, "w") as f:
        f.write(content)
PYEOF

rm -f "$TMP_MONTHLY"

# ── Find Playwright ─────────────────────────────────────────
PW_PATH="$(node -e "try { console.log(require.resolve('playwright-core').replace(/\/index\.js$/, '')); } catch(e) { process.exit(1); }" 2>/dev/null)" || true

if [ -z "$PW_PATH" ]; then
  _npm_global_root="$(npm root -g 2>/dev/null || true)"
  # Check both flattened (playwright-core installed directly) and nested (installed as a
  # dependency of the full "playwright" package) locations.
  for candidate in \
    "${_npm_global_root}/playwright-core" \
    "${_npm_global_root}/playwright/node_modules/playwright-core" \
    "${HOME}/node_modules/playwright-core" \
    "${HOME}/node_modules/playwright/node_modules/playwright-core" \
    "${HOME}/claude cowork/node_modules/playwright-core" \
    "/opt/homebrew/lib/node_modules/playwright-core" \
    "/opt/homebrew/lib/node_modules/playwright/node_modules/playwright-core"; do
    if [ -d "$candidate" ]; then
      PW_PATH="$candidate"
      break
    fi
  done
fi

if [ -z "$PW_PATH" ]; then
  echo "Error: playwright-core not found." >&2
  echo "Install: npm install -g playwright-core && npx playwright install chromium" >&2
  rm -f "$TMP_SUMMARY" "$TMP_DETAILED"
  exit 1
fi

# ── Export PNGs ──────────────────────────────────────────────
echo "Exporting PNGs via Playwright..."

PORT=8799
# Copy logo to /tmp so the HTTP server can serve it
cp -f "$TEMPLATE_DIR/dm-logo-ai.svg" /tmp/dm-logo-ai.svg 2>/dev/null || true
python3 -m http.server "$PORT" --directory /tmp &>/dev/null &
SERVER_PID=$!
trap "kill $SERVER_PID 2>/dev/null; rm -f $TMP_SUMMARY $TMP_DETAILED" EXIT
sleep 0.5

export_png() {
  local html_file="$1" output="$2" label="$3"
  local filename="$(basename "$html_file")"
  local url="http://localhost:${PORT}/${filename}"

  node -e "
const { chromium } = require('${PW_PATH}');
(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({
    viewport: { width: 1080, height: 1080 },
    deviceScaleFactor: 2
  });
  await page.goto('${url}', { waitUntil: 'networkidle' });
  await page.waitForTimeout(2000);
  await page.screenshot({
    path: '${output}',
    clip: { x: 0, y: 0, width: 1080, height: 1080 }
  });
  await browser.close();
})();
" 2>&1

  if [ -f "$output" ]; then
    local size="$(du -h "$output" | cut -f1 | tr -d ' ')"
    echo "  ${label}: ${output} (${size})"
  else
    echo "  ${label}: FAILED" >&2
  fi
}

export_png "$TMP_SUMMARY" "$EXPORT_DIR/claude-footprint-summary-${TODAY}.png" "Summary"
export_png "$TMP_DETAILED" "$EXPORT_DIR/claude-footprint-detailed-${TODAY}.png" "Detailed"

echo ""
echo "Done. ${EXPORT_DIR}/"
