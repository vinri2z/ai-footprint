#!/usr/bin/env bash
set -euo pipefail

# recompute.sh — Re-derive co2_grams and water_liters for stored `usage` rows from their raw
# token counts and the CURRENT data/factors.json, without re-running tokscale. Run after
# changing CO2/water factors, the cache_read_factor, or the family_patterns mapping.
#
# This is the answer to the providers' ~30-day transcript purge: the raw token breakdown is
# snapshotted by ingest-tokscale.sh while the data is still on disk and frozen in the `usage`
# table; everything derived from it (CO2, water) stays regenerable forever. cost_usd comes
# straight from tokscale at ingest time and is left untouched here.
#
# Family is resolved per row via family_patterns (lib-factors.sh), so a model's tier follows
# the current mapping even if it was ingested under an older one.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-factors.sh
source "${SCRIPT_DIR}/lib-factors.sh"
DB_PATH="${CLAUDE_CARBON_DB:-${HOME}/.claude/claude-carbon/carbon.db}"

[ -f "$DB_PATH" ] || { echo "No database at ${DB_PATH}" >&2; exit 1; }

CRF="$CACHE_READ_FACTOR"

# Re-resolve family for every distinct model, then bulk-update that family's rows.
# co2   = ((input + cache_write)*fin + cache_read*(fin*CRF) + output*fout) / 1e6
# water = ((input + cache_write)*win + cache_read*(win*CRF) + output*wout) / 1e6
ROWS=0
while IFS=$'\t' read -r model; do
  [ -n "${model:-}" ] || continue
  m_esc="$(printf '%s' "$model" | sed "s/'/''/g")"

  if [ "$(is_excluded "$model")" = "1" ]; then
    sqlite3 "$DB_PATH" "UPDATE usage SET co2_grams=0, water_liters=0, family='excluded', excluded=1 WHERE model='${m_esc}';"
    continue
  fi

  family="$(resolve_family "$model")"
  fin="$(factor "$family" co2_in)";  fout="$(factor "$family" co2_out)"
  win="$(factor "$family" water_in)"; wout="$(factor "$family" water_out)"

  sqlite3 "$DB_PATH" "
    UPDATE usage SET
      family='${family}',
      excluded=0,
      co2_grams    = ((input_tokens + cache_write_tokens)*${fin} + cache_read_tokens*(${fin}*${CRF}) + output_tokens*${fout}) / 1000000.0,
      water_liters = ((input_tokens + cache_write_tokens)*${win} + cache_read_tokens*(${win}*${CRF}) + output_tokens*${wout}) / 1000000.0
    WHERE model='${m_esc}';
  "
done < <(sqlite3 -separator $'\t' "$DB_PATH" "SELECT DISTINCT model FROM usage;")

ROWS="$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM usage;")"
TOTAL_CO2_KG="$(sqlite3 "$DB_PATH" "SELECT printf('%.1f', COALESCE(SUM(co2_grams),0)/1000.0) FROM usage;")"
TOTAL_WATER_L="$(sqlite3 "$DB_PATH" "SELECT printf('%.0f', COALESCE(SUM(water_liters),0)) FROM usage;")"

echo "Recomputed CO2/water for ${ROWS} usage rows."
echo "DB totals now: ${TOTAL_CO2_KG} kg CO2 / ${TOTAL_WATER_L} L water."
