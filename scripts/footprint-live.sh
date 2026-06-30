#!/usr/bin/env bash
# footprint-live.sh — compute + display carbon/water footprint directly from tokscale.
#
# No SQLite required. Calls tokscale models --json for the requested date range, applies
# the project methodology (lib-factors.sh), and prints the same report format as
# footprint-report — but stateless and always current.
#
# Usage:
#   footprint-live.sh                          # today
#   footprint-live.sh --range week|month|year  # calendar-aligned ranges
#   footprint-live.sh --since YYYY-MM-DD --until YYYY-MM-DD
#
# Limitations vs the DB-backed report:
#   - No all-time totals beyond tokscale's retention window (~30 days for Claude Code)
#   - No historical trend / per-day breakdown
#   - Requires active tokscale session (no offline fallback)

set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-factors.sh
source "${SCRIPT_DIR}/lib-factors.sh"

TOKSCALE="${CLAUDE_FOOTPRINT_TOKSCALE:-npx --yes tokscale@latest}"
run_tokscale() { $TOKSCALE "$@" --no-spinner 2>/dev/null; }

TODAY="$(python3 -c 'import datetime;print(datetime.date.today().isoformat())')"
SINCE="$TODAY"
UNTIL="$TODAY"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)  SINCE="${2:?--since requires a date}"; shift 2 ;;
    --until)  UNTIL="${2:?--until requires a date}"; shift 2 ;;
    --range)
      case "${2:-}" in
        today) SINCE="$TODAY"; UNTIL="$TODAY" ;;
        week)
          SINCE="$(python3 -c "import datetime;print((datetime.date.today()-datetime.timedelta(days=6)).isoformat())")"
          UNTIL="$TODAY" ;;
        month)
          SINCE="$(python3 -c "import datetime;d=datetime.date.today();print(d.replace(day=1).isoformat())")"
          UNTIL="$TODAY" ;;
        year)
          SINCE="$(python3 -c "import datetime;d=datetime.date.today();print(d.replace(month=1,day=1).isoformat())")"
          UNTIL="$TODAY" ;;
        *) echo "Unknown --range value: ${2:-} (valid: today week month year)" >&2; exit 2 ;;
      esac
      shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

# --- Factor cache (avoids re-reading factors.json per entry) ---
declare -a FAMS=(fable opus sonnet haiku frontier mid small default)
fam_co2_in()  { eval "echo \"\$CO2IN_$1\""; }
fam_co2_out() { eval "echo \"\$CO2OUT_$1\""; }
fam_w_in()    { eval "echo \"\$WIN_$1\""; }
fam_w_out()   { eval "echo \"\$WOUT_$1\""; }
for f in "${FAMS[@]}"; do
  eval "CO2IN_$f=\"\$(factor "$f" co2_in)\""
  eval "CO2OUT_$f=\"\$(factor "$f" co2_out)\""
  eval "WIN_$f=\"\$(factor "$f" water_in)\""
  eval "WOUT_$f=\"\$(factor "$f" water_out)\""
done

# --- Fetch from tokscale (one call covers the full range) ---
ENTRIES="$(run_tokscale models --json \
  --group-by client,provider,model \
  --since "$SINCE" --until "$UNTIL" \
  | jq -r '.entries[]? | [(.client//"unknown"),(.provider//"unknown"),(.model//"unknown"),(.input//0),(.output//0),(.cacheRead//0),(.cacheWrite//0),(.reasoning//0),(.cost//0)] | @tsv' \
  || true)"

if [ -z "$ENTRIES" ]; then
  if [ "$SINCE" = "$UNTIL" ]; then
    echo "No usage data for ${SINCE}."
  else
    echo "No usage data for ${SINCE}..${UNTIL}."
  fi
  exit 0
fi

# --- Process entries: compute footprint, write pipe-delimited rows ---
# Format: client|provider|model|co2_g|water_l|cost_usd
TMPFILE="$(mktemp)"
trap 'rm -f "$TMPFILE"' EXIT

while IFS=$'\t' read -r client provider model input output cache_read cache_write reasoning cost; do
  [ -n "${model:-}" ] || continue
  out_total=$(( ${output:-0} + ${reasoning:-0} ))

  if [ "$(is_excluded "$model")" = "1" ]; then
    continue
  fi

  family="$(resolve_family "$model")"
  fin="$(fam_co2_in  "$family")"; fout="$(fam_co2_out "$family")"
  win="$(fam_w_in    "$family")"; wout="$(fam_w_out  "$family")"
  read -r co2 water <<< "$(compute_footprint \
    "${input:-0}" "${cache_write:-0}" "${cache_read:-0}" "$out_total" \
    "$fin" "$fout" "$win" "$wout")"

  printf '%s|%s|%s|%s|%s|%s\n' \
    "$client" "$provider" "$model" "$co2" "$water" "${cost:-0}" >> "$TMPFILE"
done <<< "$ENTRIES"

if [ ! -s "$TMPFILE" ]; then
  echo "No non-excluded usage data for ${SINCE}..${UNTIL}."
  exit 0
fi

# --- Aggregate totals ---
read -r TOTAL_CO2 TOTAL_WATER TOTAL_COST AGENT_COUNT < <(
  awk -F'|' '{
    co2 += $4; water += $5; cost += $6; clients[$1] = 1
  }
  END { printf "%.1f %.2f %.2f %d\n", co2, water, cost, length(clients) }' "$TMPFILE"
)

# --- CO2 equivalences ---
# ENERGY_KWH backs out inference energy from CO2 via CIF (0.287 kgCO2e/kWh = 287 gCO2e/kWh,
# see METHODOLOGY.md Infrastructure parameters) — kWh, EV km and TGV km are all derived from it.
KM_CAR="$(echo "$TOTAL_CO2" | awk '{printf "%.0f", $1 / 120}')"
GOOGLE="$(echo  "$TOTAL_CO2" | awk '{printf "%.0f", $1 / 0.2}')"
FLIGHTS="$(echo "$TOTAL_CO2" | awk '{printf "%.4f", $1 / 400000}')"
ENERGY_KWH="$(echo "$TOTAL_CO2" | awk '{printf "%.3f", $1 / 287}')"
KM_EV="$(echo "$ENERGY_KWH" | awk '{printf "%.0f", $1 / 0.18}')"
KM_TGV="$(echo "$ENERGY_KWH" | awk '{printf "%.0f", $1 / 0.056}')"

# --- Water equivalences ---
BOTTLES="$(echo "$TOTAL_WATER" | awk '{printf "%.0f", $1 / 0.5}')"
SHOWERS="$(echo "$TOTAL_WATER" | awk '{printf "%.1f", $1 / 65}')"

# --- By agent ---
BY_AGENT="$(awk -F'|' '{co2[$1]+=$4; water[$1]+=$5; cost[$1]+=$6}
  END{for(c in co2) printf "%s|%.2f|%.3f|%.2f\n",c,co2[c],water[c],cost[c]}' \
  "$TMPFILE" | sort -t'|' -k2 -rn)"

# --- By provider ---
BY_PROVIDER="$(awk -F'|' '{co2[$2]+=$4; water[$2]+=$5; cost[$2]+=$6}
  END{for(p in co2) printf "%s|%.2f|%.3f|%.2f\n",p,co2[p],water[p],cost[p]}' \
  "$TMPFILE" | sort -t'|' -k2 -rn)"

# --- Top 8 models (key = model|client) ---
TOP_MODELS="$(awk -F'|' '{
    k=$3"|"$1; co2[k]+=$4; water[k]+=$5; cost[k]+=$6
  }
  END{for(k in co2) printf "%s|%.2f|%.3f|%.2f\n",k,co2[k],water[k],cost[k]}' \
  "$TMPFILE" | sort -t'|' -k3 -rn | head -8)"

# --- Display ---
echo "==============================="
echo "  claude-footprint live report"
echo "  (tokscale direct, no DB)"
echo "==============================="
echo ""
if [ "$SINCE" = "$UNTIL" ]; then
  echo "${SINCE}"
else
  echo "${SINCE} → ${UNTIL}"
fi
echo "  CO2       : ${TOTAL_CO2}g"
echo "  Water     : ${TOTAL_WATER}L"
echo "  Cost      : \$${TOTAL_COST}"
echo "  Agents    : ${AGENT_COUNT}"
echo ""
echo "--- CO2 equivalences ---"
echo "  ${KM_CAR} km by car            (120 gCO2e/km)"
echo "  ${GOOGLE} Google searches       (0.2 gCO2e)"
echo "  ${FLIGHTS} Paris↔New-York flights (400 kg CO2e/pax one-way)"
echo ""
echo "--- Energy equivalences (${ENERGY_KWH} kWh estimated) ---"
echo "  ${KM_EV} km by electric car     (0.18 kWh/km)"
echo "  ${KM_TGV} km by TGV             (0.056 kWh/passenger-km)"
echo ""
echo "--- Water equivalences ---"
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
