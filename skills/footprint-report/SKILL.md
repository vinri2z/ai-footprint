---
name: footprint-report
description: Display CO2 and water footprint report across all AI coding agents (Claude Code, Codex, Cursor, Gemini, ...)
---

Run the following bash script exactly as written and present the output to the user. Do not paraphrase or reformat the results.

```bash
#!/usr/bin/env bash

# Force C locale: comma-decimal locales (de_DE, fr_FR) make awk mis-parse
# "431.7045" as 431 and print "431,0" instead of "431.7"
export LC_ALL=C

DB_PATH="${HOME}/.claude/claude-carbon/carbon.db"

if [ ! -f "$DB_PATH" ]; then
  echo "Database not found. Run setup.sh first:"
  echo "  bash ~/code/ai-footprint/scripts/setup.sh"
  exit 1
fi

if ! sqlite3 "$DB_PATH" "SELECT 1 FROM usage LIMIT 1;" >/dev/null 2>&1; then
  echo "No multi-agent usage yet. Backfill with:"
  echo "  bash ~/code/ai-footprint/scripts/ingest-tokscale.sh"
  exit 1
fi

CURRENT_YEAR="$(date +%Y)"
TODAY="$(date +%Y-%m-%d)"

# Excluded rows (e.g. <synthetic>) are left out of all aggregates.
NOT_EXCLUDED="COALESCE(excluded, 0) = 0"

# --- Aggregates (usage.date is YYYY-MM-DD) ---
TODAY_CO2="$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(co2_grams), 0) FROM usage WHERE ${NOT_EXCLUDED} AND date = '${TODAY}';" | awk '{printf "%.1f", $1}')"
TODAY_WATER="$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(water_liters), 0) FROM usage WHERE ${NOT_EXCLUDED} AND date = '${TODAY}';" | awk '{printf "%.2f", $1}')"
TODAY_AGENTS="$(sqlite3 "$DB_PATH" "SELECT COUNT(DISTINCT client) FROM usage WHERE ${NOT_EXCLUDED} AND date = '${TODAY}';")"

YEAR_CO2="$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(co2_grams), 0) FROM usage WHERE ${NOT_EXCLUDED} AND date LIKE '${CURRENT_YEAR}%';" | awk '{printf "%.1f", $1}')"
YEAR_WATER="$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(water_liters), 0) FROM usage WHERE ${NOT_EXCLUDED} AND date LIKE '${CURRENT_YEAR}%';" | awk '{printf "%.2f", $1}')"
YEAR_AGENTS="$(sqlite3 "$DB_PATH" "SELECT COUNT(DISTINCT client) FROM usage WHERE ${NOT_EXCLUDED} AND date LIKE '${CURRENT_YEAR}%';")"

ALL_CO2="$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(co2_grams), 0) FROM usage WHERE ${NOT_EXCLUDED};" | awk '{printf "%.1f", $1}')"
ALL_WATER="$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(water_liters), 0) FROM usage WHERE ${NOT_EXCLUDED};" | awk '{printf "%.2f", $1}')"
ALL_AGENTS="$(sqlite3 "$DB_PATH" "SELECT COUNT(DISTINCT client) FROM usage WHERE ${NOT_EXCLUDED};")"
ALL_COST="$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(cost_usd), 0) FROM usage WHERE ${NOT_EXCLUDED};" | awk '{printf "%.2f", $1}')"

# --- CO2 equivalences (all-time total) ---
KM_CAR="$(echo "$ALL_CO2" | awk '{printf "%.0f", $1 / 120}')"
GOOGLE="$(echo "$ALL_CO2" | awk '{printf "%.0f", $1 / 0.2}')"
KM_TGV="$(echo "$ALL_CO2" | awk '{printf "%.0f", $1 / 2.4}')"

# --- Water equivalences (all-time total) ---
BOTTLES="$(echo "$ALL_WATER" | awk '{printf "%.0f", $1 / 0.5}')"
SHOWERS="$(echo "$ALL_WATER" | awk '{printf "%.1f", $1 / 65}')"

# --- By agent (tokscale client) ---
BY_AGENT="$(sqlite3 -separator '|' "$DB_PATH" \
  "SELECT client, ROUND(SUM(co2_grams), 2), ROUND(SUM(COALESCE(water_liters,0)), 3), ROUND(SUM(cost_usd), 2)
   FROM usage WHERE ${NOT_EXCLUDED}
   GROUP BY client ORDER BY SUM(co2_grams) DESC;")"

# --- By provider ---
BY_PROVIDER="$(sqlite3 -separator '|' "$DB_PATH" \
  "SELECT provider, ROUND(SUM(co2_grams), 2), ROUND(SUM(COALESCE(water_liters,0)), 3), ROUND(SUM(cost_usd), 2)
   FROM usage WHERE ${NOT_EXCLUDED}
   GROUP BY provider ORDER BY SUM(co2_grams) DESC;")"

# --- Top 8 models by CO2 ---
TOP_MODELS="$(sqlite3 -separator '|' "$DB_PATH" \
  "SELECT model, client, ROUND(SUM(co2_grams), 2), ROUND(SUM(COALESCE(water_liters,0)), 3), ROUND(SUM(cost_usd), 2)
   FROM usage WHERE ${NOT_EXCLUDED}
   GROUP BY model, client ORDER BY SUM(co2_grams) DESC LIMIT 8;")"

echo "==============================="
echo "  ai-footprint report"
echo "  (all agents via tokscale)"
echo "==============================="
echo ""
echo "Today (${TODAY})"
echo "  CO2       : ${TODAY_CO2}g"
echo "  Water     : ${TODAY_WATER}L"
echo "  Agents    : ${TODAY_AGENTS}"
echo ""
echo "${CURRENT_YEAR}"
echo "  CO2       : ${YEAR_CO2}g"
echo "  Water     : ${YEAR_WATER}L"
echo "  Agents    : ${YEAR_AGENTS}"
echo ""
echo "All time"
echo "  CO2       : ${ALL_CO2}g"
echo "  Water     : ${ALL_WATER}L"
echo "  Agents    : ${ALL_AGENTS}"
echo "  Cost      : \$${ALL_COST}"
echo ""
echo "--- CO2 equivalences (all-time) ---"
echo "  ${KM_CAR} km by car            (120 gCO2e/km)"
echo "  ${GOOGLE} Google searches       (0.2 gCO2e)"
echo "  ${KM_TGV} km by train           (2.4 gCO2e/km)"
echo ""
echo "--- Water equivalences (all-time) ---"
echo "  ${BOTTLES} water bottles          (0.5 L)"
echo "  ${SHOWERS} showers                (65 L)"
echo ""
echo "--- By agent ---"
echo "Agent                | CO2 (g)   | Water(L)  | Cost"
echo "---------------------|-----------|-----------|--------"
while IFS='|' read -r client co2 water cost; do
  [ -n "$client" ] || continue
  printf "%-20s | %-9s | %-9s | \$%s\n" "$client" "$co2" "$water" "$cost"
done <<< "$BY_AGENT"
echo ""
echo "--- By provider ---"
echo "Provider             | CO2 (g)   | Water(L)  | Cost"
echo "---------------------|-----------|-----------|--------"
while IFS='|' read -r provider co2 water cost; do
  [ -n "$provider" ] || continue
  printf "%-20s | %-9s | %-9s | \$%s\n" "$provider" "$co2" "$water" "$cost"
done <<< "$BY_PROVIDER"
echo ""
echo "--- Top models by CO2 ---"
echo "Model                          | Agent        | CO2 (g)   | Water(L)  | Cost"
echo "-------------------------------|--------------|-----------|-----------|--------"
while IFS='|' read -r model client co2 water cost; do
  [ -n "$model" ] || continue
  printf "%-30s | %-12s | %-9s | %-9s | \$%s\n" "$model" "$client" "$co2" "$water" "$cost"
done <<< "$TOP_MODELS"
echo ""
```
