#!/usr/bin/env bash
# lib-factors.sh — shared footprint helpers, sourced by ingest-tokscale.sh and recompute.sh.
#
# Maps a model string to a family (data-driven via factors.json family_patterns), exposes the
# per-family CO2/water factors, and computes CO2/water for a token breakdown using the single
# canonical formula:
#   CO2   = ((input + cache_write)*fin + cache_read*(fin*CRF) + output*fout) / 1e6
#   Water = ((input + cache_write)*win + cache_read*(win*CRF) + output*wout) / 1e6
# where `output` already includes reasoning tokens (generated tokens are billed/emitted alike).
#
# Portable to bash 3.2 (macOS default): no associative arrays. Factor lookups go through jq so
# adding a family is a factors.json edit only.

FACTORS_FILE="${CLAUDE_CARBON_FACTORS:-${FACTORS_FILE:-}}"
if [ -z "$FACTORS_FILE" ]; then
  _lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  FACTORS_FILE="${_lib_dir}/../data/factors.json"
fi

# Energy of a cache_read token as a fraction of an uncached input token (see METHODOLOGY.md).
CACHE_READ_FACTOR="$(jq -r '.cache_read_factor // 0.08' "$FACTORS_FILE" 2>/dev/null)" || CACHE_READ_FACTOR="0.08"

# resolve_family <model> -> family name (first matching family_patterns entry, else "default").
resolve_family() {
  jq -r --arg m "$1" '
    ([ (.family_patterns // [])[] | . as $e | ($m // "") | select(test($e.pattern; "i")) | $e.family ] | .[0]) // "default"
  ' "$FACTORS_FILE" 2>/dev/null || echo "default"
}

# is_excluded <model> -> prints 1 when the model matches an exclude_models pattern, else 0.
is_excluded() {
  jq -r --arg m "$1" '
    if ([ (.exclude_models // [])[] | . as $p | ($m // "") | select(test($p; "i")) ] | length) > 0 then 1 else 0 end
  ' "$FACTORS_FILE" 2>/dev/null || echo 0
}

# factor <family> <key>  where key in: co2_in co2_out water_in water_out
factor() {
  local family="$1" key="$2"
  case "$key" in
    co2_in)    jq -r --arg f "$family" '.models[$f].input // .models.default.input' "$FACTORS_FILE" ;;
    co2_out)   jq -r --arg f "$family" '.models[$f].output // .models.default.output' "$FACTORS_FILE" ;;
    water_in)  jq -r --arg f "$family" '.water_factors[$f].input // .water_factors.default.input' "$FACTORS_FILE" ;;
    water_out) jq -r --arg f "$family" '.water_factors[$f].output // .water_factors.default.output' "$FACTORS_FILE" ;;
  esac
}

# compute_footprint <input> <cache_write> <cache_read> <output> <fin> <fout> <win> <wout>
# Prints: "<co2_grams> <water_liters>" (co2 %.6f, water %.6f).
compute_footprint() {
  echo "$1 $2 $3 $4 $5 $6 $7 $8 $CACHE_READ_FACTOR" | LC_ALL=C awk '{
    crf=$9;
    co2   = (($1 + $2) * $5 + $3 * ($5 * crf) + $4 * $6) / 1000000;
    water = (($1 + $2) * $7 + $3 * ($7 * crf) + $4 * $8) / 1000000;
    printf "%.6f %.6f", co2, water;
  }'
}
