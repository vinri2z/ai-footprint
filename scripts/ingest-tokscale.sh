#!/usr/bin/env bash
set -euo pipefail

# ingest-tokscale.sh — single source of persisted usage for claude-footprint.
#
# Pulls per-(client, provider, model) token usage from tokscale (which scans 30+ AI coding
# agents — Claude Code, Codex, Cursor, Gemini CLI, Copilot, OpenCode, ...) one day at a time,
# computes CO2 + water with the project methodology (data/factors.json), takes cost straight
# from tokscale, and upserts one row per (date, client, provider, model) into the `usage`
# table. Idempotent: re-ingesting a day replaces its rows (INSERT OR REPLACE on the PK).
#
# Why per-day: tokscale reads live transcripts, which providers purge (~30 days for Claude
# Code). Snapshotting daily into our own DB preserves history beyond that window and keeps the
# today / current-year / all-time report buckets exact. Raw token columns are stored so
# recompute.sh can re-derive CO2/water after a factors.json change without re-running tokscale.
#
# Usage:
#   ingest-tokscale.sh                 # full backfill (earliest tokscale data -> today)
#   ingest-tokscale.sh --today         # just today (used by the Stop hook)
#   ingest-tokscale.sh --days N        # last N days
#   ingest-tokscale.sh --since D --until D   # explicit YYYY-MM-DD range (inclusive)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-factors.sh
source "${SCRIPT_DIR}/lib-factors.sh"

DB_PATH="${CLAUDE_CARBON_DB:-${HOME}/.claude/claude-carbon/carbon.db}"
METHODOLOGY_VERSION=2
BACKFILL_CAP_DAYS="${CLAUDE_FOOTPRINT_BACKFILL_CAP_DAYS:-400}"

# tokscale invocation (override for testing). --no-spinner keeps JSON clean for scripts.
TOKSCALE="${CLAUDE_FOOTPRINT_TOKSCALE:-npx --yes tokscale@latest}"

[ -f "$DB_PATH" ] || { echo "No database at ${DB_PATH}. Run setup.sh first." >&2; exit 1; }

run_tokscale() { $TOKSCALE "$@" --no-spinner 2>/dev/null; }

# --- Resolve the date range -------------------------------------------------
TODAY="$(python3 -c 'import datetime;print(datetime.date.today().isoformat())')"
SINCE=""; UNTIL="$TODAY"

case "${1:-}" in
  --today)
    SINCE="$TODAY" ;;
  --days)
    SINCE="$(python3 -c "import datetime,sys;print((datetime.date.today()-datetime.timedelta(days=int(sys.argv[1])-1)).isoformat())" "${2:-7}")" ;;
  --since)
    SINCE="${2:-}"; [ "${3:-}" = "--until" ] && UNTIL="${4:-$TODAY}" ;;
  ""|--backfill)
    # Earliest month tokscale knows about -> first of that month.
    EARLIEST_MONTH="$(run_tokscale monthly --json | jq -r '[.entries[].month] | min // empty')"
    if [ -n "$EARLIEST_MONTH" ]; then
      SINCE="${EARLIEST_MONTH}-01"
    else
      SINCE="$(python3 -c 'import datetime;print((datetime.date.today()-datetime.timedelta(days=34)).isoformat())')"
    fi ;;
  *)
    echo "Unknown argument: $1" >&2; exit 2 ;;
esac
[ -n "$SINCE" ] || { echo "Could not resolve start date." >&2; exit 1; }

# Cap an over-long backfill window (keeps the day-loop bounded).
SPAN="$(python3 -c "import datetime,sys;a=datetime.date.fromisoformat(sys.argv[1]);b=datetime.date.fromisoformat(sys.argv[2]);print((b-a).days)" "$SINCE" "$UNTIL")"
if [ "$SPAN" -gt "$BACKFILL_CAP_DAYS" ]; then
  SINCE="$(python3 -c "import datetime,sys;print((datetime.date.fromisoformat(sys.argv[2])-datetime.timedelta(days=int(sys.argv[1]))).isoformat())" "$BACKFILL_CAP_DAYS" "$UNTIL")"
  echo "Note: backfill window capped to last ${BACKFILL_CAP_DAYS} days (from ${SINCE})." >&2
fi

# --- Factor cache (8 known families; avoids re-reading factors.json per entry) ----
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

sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

# --- Day loop ---------------------------------------------------------------
DATES="$(python3 -c "import datetime,sys;a=datetime.date.fromisoformat(sys.argv[1]);b=datetime.date.fromisoformat(sys.argv[2]);print('\n'.join((a+datetime.timedelta(d)).isoformat() for d in range((b-a).days+1)))" "$SINCE" "$UNTIL")"

NOW="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
TOTAL_ROWS=0
TOTAL_DAYS=0

for DAY in $DATES; do
  TOTAL_DAYS=$((TOTAL_DAYS + 1))
  ENTRIES="$(run_tokscale models --json --group-by client,provider,model --since "$DAY" --until "$DAY" \
    | jq -r '.entries[]? | [(.client//"unknown"),(.provider//"unknown"),(.model//"unknown"),(.input//0),(.output//0),(.cacheRead//0),(.cacheWrite//0),(.reasoning//0),(.cost//0)] | @tsv' || true)"
  [ -n "$ENTRIES" ] || continue

  SQL=""
  while IFS=$'\t' read -r client provider model input output cache_read cache_write reasoning cost; do
    [ -n "${model:-}" ] || continue
    out_total=$(( ${output:-0} + ${reasoning:-0} ))

    if [ "$(is_excluded "$model")" = "1" ]; then
      family="excluded"; co2="0"; water="0"; excluded=1
    else
      family="$(resolve_family "$model")"
      fin="$(fam_co2_in "$family")";  fout="$(fam_co2_out "$family")"
      win="$(fam_w_in "$family")";    wout="$(fam_w_out "$family")"
      read -r co2 water <<< "$(compute_footprint "$input" "$cache_write" "$cache_read" "$out_total" "$fin" "$fout" "$win" "$wout")"
      excluded=0
    fi

    c="$(sql_escape "$client")"; p="$(sql_escape "$provider")"; m="$(sql_escape "$model")"; fa="$(sql_escape "$family")"
    SQL="${SQL}INSERT OR REPLACE INTO usage (date,client,provider,model,family,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,co2_grams,water_liters,cost_usd,excluded,methodology_version,source,updated_at) VALUES ('${DAY}','${c}','${p}','${m}','${fa}',${input:-0},${out_total},${cache_read:-0},${cache_write:-0},${co2},${water},${cost:-0},${excluded},${METHODOLOGY_VERSION},'tokscale','${NOW}');
"
    TOTAL_ROWS=$((TOTAL_ROWS + 1))
  done <<< "$ENTRIES"

  [ -n "$SQL" ] && printf 'BEGIN;\n%sCOMMIT;\n' "$SQL" | sqlite3 "$DB_PATH"
done

echo "Ingested ${TOTAL_ROWS} usage rows across ${TOTAL_DAYS} day(s) (${SINCE}..${UNTIL})."
