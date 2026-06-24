#!/usr/bin/env bash
# run-vectors.sh — Replay tests/methodology-vectors.json against the plugin's CO2/water math.
#
# CO2 + water are validated against the REAL shared code (scripts/lib-factors.sh: resolve_family,
# is_excluded, factor, compute_footprint) so the test tracks ingest-tokscale.sh / recompute.sh
# exactly. cost_usd is validated only for Claude families (prices.json) — for non-Anthropic
# agents the footprint pipeline takes cost straight from tokscale, so those vectors set
# expected_cost_usd: null and the cost check is skipped.
#
# bash 3.2 compatible (macOS default): no associative arrays, no mapfile. Deps: jq, awk.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FACTORS_FILE="${SCRIPT_DIR}/../data/factors.json"
PRICES_FILE="${SCRIPT_DIR}/../data/prices.json"
VECTORS_FILE="${SCRIPT_DIR}/methodology-vectors.json"
REL_TOL="0.000001" # 1e-6

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required" >&2; exit 1; }
[ -f "$FACTORS_FILE" ] || { echo "FAIL: missing $FACTORS_FILE" >&2; exit 1; }
[ -f "$PRICES_FILE" ] || { echo "FAIL: missing $PRICES_FILE" >&2; exit 1; }
[ -f "$VECTORS_FILE" ] || { echo "FAIL: missing $VECTORS_FILE" >&2; exit 1; }

# Source the production helpers so the test validates the same code ingest/recompute use.
# shellcheck source=../scripts/lib-factors.sh
source "${SCRIPT_DIR}/../scripts/lib-factors.sh"

# Prices (USD per Mtok) + cache multipliers — Claude families only (statusline live cost).
P_FAB_IN="$(jq -r '.models.fable.input' "$PRICES_FILE")";  P_FAB_OUT="$(jq -r '.models.fable.output' "$PRICES_FILE")"
P_OPUS_IN="$(jq -r '.models.opus.input' "$PRICES_FILE")";  P_OPUS_OUT="$(jq -r '.models.opus.output' "$PRICES_FILE")"
P_SON_IN="$(jq -r '.models.sonnet.input' "$PRICES_FILE")"; P_SON_OUT="$(jq -r '.models.sonnet.output' "$PRICES_FILE")"
P_HAI_IN="$(jq -r '.models.haiku.input' "$PRICES_FILE")";  P_HAI_OUT="$(jq -r '.models.haiku.output' "$PRICES_FILE")"
CW_MULT="$(jq -r '.cache_write_multiplier // 1.25' "$PRICES_FILE")"
CR_MULT="$(jq -r '.cache_read_multiplier // 0.1' "$PRICES_FILE")"

# Relative-tolerance comparison (absolute when expected == 0). Returns 0 on match.
close_enough() {
  echo "$1 $2 $REL_TOL" | LC_ALL=C awk '{
    actual = $1; expected = $2; tol = $3;
    diff = actual - expected; if (diff < 0) diff = -diff;
    ref = expected; if (ref < 0) ref = -ref;
    if (ref == 0) { exit (diff <= tol) ? 0 : 1 }
    exit (diff / ref <= tol) ? 0 : 1
  }'
}

N="$(jq '.vectors | length' "$VECTORS_FILE")"
FAILURES=0
PASSED=0
i=0
while [ "$i" -lt "$N" ]; do
  ROW="$(jq -r --argjson i "$i" '.vectors[$i] | [
    .id, .model,
    (.input_tokens // 0), (.cache_creation_tokens // 0),
    (.cache_read_tokens // 0), (.output_tokens // 0),
    (if .excluded == true then "1" else "0" end),
    (.expected_co2_grams // 0), (.expected_water_liters // 0),
    (if .expected_cost_usd == null then "skip" else (.expected_cost_usd|tostring) end)
  ] | @tsv' "$VECTORS_FILE")"
  IFS="$(printf '\t')" read -r ID MODEL IN CW CR OUT EXCLUDED EXP_CO2 EXP_WATER EXP_COST <<EOF
$ROW
EOF

  if [ "$(is_excluded "$MODEL")" = "1" ]; then
    if [ "$EXCLUDED" != "1" ]; then
      echo "FAIL ${ID}: model '${MODEL}' is excluded by the plugin but the vector is not marked excluded"
      FAILURES=$((FAILURES + 1)); i=$((i + 1)); continue
    fi
    CO2="0"; WATER="0"; EXP_CO2="0"; EXP_WATER="0"; EXP_COST="skip"
  else
    if [ "$EXCLUDED" = "1" ]; then
      echo "FAIL ${ID}: vector marked excluded but model '${MODEL}' is not excluded by the plugin"
      FAILURES=$((FAILURES + 1)); i=$((i + 1)); continue
    fi
    FAMILY="$(resolve_family "$MODEL")"
    FIN="$(factor "$FAMILY" co2_in)";  FOUT="$(factor "$FAMILY" co2_out)"
    WIN="$(factor "$FAMILY" water_in)"; WOUT="$(factor "$FAMILY" water_out)"
    read -r CO2 WATER <<< "$(compute_footprint "$IN" "$CW" "$CR" "$OUT" "$FIN" "$FOUT" "$WIN" "$WOUT")"

    # Cost: Claude families only (prices.json). Other families take cost from tokscale.
    if [ "$EXP_COST" != "skip" ]; then
      case "$FAMILY" in
        fable) PIN="$P_FAB_IN"; POUT="$P_FAB_OUT" ;;
        opus)  PIN="$P_OPUS_IN"; POUT="$P_OPUS_OUT" ;;
        haiku) PIN="$P_HAI_IN"; POUT="$P_HAI_OUT" ;;
        sonnet) PIN="$P_SON_IN"; POUT="$P_SON_OUT" ;;
        *) PIN=""; POUT="" ;;
      esac
      if [ -n "$PIN" ]; then
        COST="$(echo "$IN $CW $CR $OUT $PIN $POUT $CW_MULT $CR_MULT" | LC_ALL=C awk \
          '{printf "%.6f", ($1 * $5 + $2 * ($5 * $7) + $3 * ($5 * $8) + $4 * $6) / 1000000}')"
      else
        EXP_COST="skip"
      fi
    fi
  fi

  OK=1
  if ! close_enough "$CO2" "$EXP_CO2"; then
    echo "FAIL ${ID}: co2_grams ${CO2} != expected ${EXP_CO2} (model ${MODEL})"
    OK=0
  fi
  if ! close_enough "$WATER" "$EXP_WATER"; then
    echo "FAIL ${ID}: water_liters ${WATER} != expected ${EXP_WATER} (model ${MODEL})"
    OK=0
  fi
  if [ "$EXP_COST" != "skip" ]; then
    if ! close_enough "$COST" "$EXP_COST"; then
      echo "FAIL ${ID}: cost_usd ${COST} != expected ${EXP_COST} (model ${MODEL})"
      OK=0
    fi
  fi
  if [ "$OK" = "1" ]; then
    echo "PASS ${ID}: co2=${CO2} g, water=${WATER} L"
    PASSED=$((PASSED + 1))
  else
    FAILURES=$((FAILURES + 1))
  fi
  i=$((i + 1))
done

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "${FAILURES}/${N} vector(s) FAILED (${PASSED} passed)."
  exit 1
fi
echo "All ${N} methodology vectors passed."
