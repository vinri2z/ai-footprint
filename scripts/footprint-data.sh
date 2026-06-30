#!/usr/bin/env bash
set -euo pipefail

# footprint-data.sh — live footprint data source for ai-footprint.
#
# Reads token usage straight from tokscale (which scans 30+ AI coding agents — Claude Code,
# Codex, Cursor, Gemini CLI, Copilot, OpenCode, ...), computes CO2 + water with the project
# methodology (data/factors.json), takes cost straight from tokscale, and prints a single
# aggregated JSON document on stdout.
#
# Computed per-bucket rows are cached in a local SQLite DB (footprint-cache.{sh,py}): buckets
# that lie wholly in the past are "sealed" and read from the cache, so each run only queries
# tokscale for live buckets (current month, recent days) and any new ones. The cache self-
# invalidates when the tokscale config / agent set changes. Set AI_FOOTPRINT_NO_CACHE=1 to
# bypass it and always query tokscale.
#
# Because tokscale's `models` report cannot group by date, time-series views are built by
# looping tokscale over time buckets:
#   • a month loop (earliest month with data -> today) backs the all-time / year totals and the
#     by-agent / by-provider / by-model / by-month aggregates;
#   • a day loop over a trailing window (default 35 days) backs the daily timeline and "today".
# tokscale itself only retains each agent's live transcripts (~30 days for Claude Code), so
# daily resolution older than that window is not reconstructable without a store — by design.
#
# Usage:
#   footprint-data.sh                       # full history (earliest month with data -> today)
#   footprint-data.sh --all                 # same as above
#   footprint-data.sh --since YYYY-MM-DD [--until YYYY-MM-DD]
#   footprint-data.sh --day-window N        # trailing days kept at daily resolution (default 35)
#
# Output JSON (all CO2 in grams, water in liters, cost in USD):
#   { today, year, all, first_date, last_date,
#     by_agent[], by_project[], by_provider[], by_model[], by_month[], by_day[] }
# where each total object is { co2, water, cost, tokens, agents, models }.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-factors.sh
source "${SCRIPT_DIR}/lib-factors.sh"

# tokscale invocation (override for testing). --no-spinner keeps JSON clean for scripts.
TOKSCALE="${AI_FOOTPRINT_TOKSCALE:-npx --yes tokscale@latest}"
BACKFILL_CAP_DAYS="${AI_FOOTPRINT_BACKFILL_CAP_DAYS:-400}"
DAY_WINDOW="${AI_FOOTPRINT_DAY_WINDOW:-35}"

run_tokscale() { $TOKSCALE "$@" --no-spinner 2>/dev/null; }

# SQLite cache: sealed (past) buckets are read from the DB instead of re-querying tokscale,
# so each run only fetches live/new buckets. Sourced after run_tokscale (cache_fingerprint
# uses it). See footprint-cache.sh / footprint-cache.py.
# shellcheck source=footprint-cache.sh
source "${SCRIPT_DIR}/footprint-cache.sh"

# --- Resolve the date range -------------------------------------------------
TODAY="$(python3 -c 'import datetime;print(datetime.date.today().isoformat())')"
SINCE=""; UNTIL="$TODAY"

while [ $# -gt 0 ]; do
  case "$1" in
    --all) SINCE=""; shift ;;
    --since) SINCE="${2:-}"; shift 2 ;;
    --until) UNTIL="${2:-$TODAY}"; shift 2 ;;
    --day-window) DAY_WINDOW="${2:-35}"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$SINCE" ]; then
  # Earliest month tokscale knows about -> first of that month.
  EARLIEST_MONTH="$(run_tokscale monthly --json | jq -r '[.entries[].month] | min // empty')"
  if [ -n "$EARLIEST_MONTH" ]; then
    SINCE="${EARLIEST_MONTH}-01"
  else
    SINCE="$(python3 -c 'import datetime;print((datetime.date.today()-datetime.timedelta(days=34)).isoformat())')"
  fi
fi

# Cap an over-long window (keeps the month/day loops bounded).
SPAN="$(python3 -c "import datetime,sys;a=datetime.date.fromisoformat(sys.argv[1]);b=datetime.date.fromisoformat(sys.argv[2]);print((b-a).days)" "$SINCE" "$UNTIL")"
if [ "$SPAN" -gt "$BACKFILL_CAP_DAYS" ]; then
  SINCE="$(python3 -c "import datetime,sys;print((datetime.date.fromisoformat(sys.argv[2])-datetime.timedelta(days=int(sys.argv[1]))).isoformat())" "$BACKFILL_CAP_DAYS" "$UNTIL")"
  echo "Note: window capped to last ${BACKFILL_CAP_DAYS} days (from ${SINCE})." >&2
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

# emit_bucket <granularity: month|day> <bucket-key> — runs tokscale for one time bucket and
# prints computed TSV rows: gran bucket client provider model family input output cr cw co2 water cost excluded workspace
#
# Grouped by workspace,model so a single tokscale pass yields the project (workspace) dimension
# alongside client/provider/model — totals are identical to a client,provider,model grouping.
emit_bucket() {
  local gran="$1" bucket="$2" since until
  if [ "$gran" = "month" ]; then
    since="${bucket}-01"
    until="$(python3 -c "import datetime,sys;y,m=map(int,sys.argv[1].split('-'));d=datetime.date(y+(m//12),(m%12)+1,1)-datetime.timedelta(days=1);print(d.isoformat())" "$bucket")"
  else
    since="$bucket"; until="$bucket"
  fi

  local entries
  entries="$(run_tokscale models --json --group-by workspace,model --since "$since" --until "$until" \
    | jq -r '.entries[]? | [(.client//"unknown"),(.provider//"unknown"),(.model//"unknown"),(.input//0),(.output//0),(.cacheRead//0),(.cacheWrite//0),(.reasoning//0),(.cost//0),(.workspaceLabel//"unknown")] | @tsv' || true)"
  [ -n "$entries" ] || return 0

  local client provider model input output cache_read cache_write reasoning cost workspace
  while IFS=$'\t' read -r client provider model input output cache_read cache_write reasoning cost workspace; do
    [ -n "${model:-}" ] || continue
    local out_total=$(( ${output:-0} + ${reasoning:-0} ))
    local family co2 water excluded
    if [ "$(is_excluded "$model")" = "1" ]; then
      family="excluded"; co2="0"; water="0"; excluded=1
    else
      family="$(resolve_family "$model")"
      local fin fout win wout
      fin="$(fam_co2_in "$family")"; fout="$(fam_co2_out "$family")"
      win="$(fam_w_in "$family")";   wout="$(fam_w_out "$family")"
      read -r co2 water <<< "$(compute_footprint "$input" "$cache_write" "$cache_read" "$out_total" "$fin" "$fout" "$win" "$wout")"
      excluded=0
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$gran" "$bucket" "$client" "$provider" "$model" "$family" \
      "${input:-0}" "$out_total" "${cache_read:-0}" "${cache_write:-0}" "$co2" "$water" "${cost:-0}" "$excluded" "${workspace:-unknown}"
  done <<< "$entries"
}

# --- Month loop (all-time / year / by-agent / by-provider / by-model / by-month) ----
MONTHS="$(python3 -c "
import datetime,sys
a=datetime.date.fromisoformat(sys.argv[1]); b=datetime.date.fromisoformat(sys.argv[2])
seen=[]; y,m=a.year,a.month
while (y,m) <= (b.year,b.month):
    seen.append(f'{y:04d}-{m:02d}')
    m+=1
    if m>12: m=1; y+=1
print('\n'.join(seen))
" "$SINCE" "$UNTIL")"

# --- Day loop (trailing window, intersected with the requested range) ---------
DAY_START="$(python3 -c "import datetime,sys;w=int(sys.argv[1]);u=datetime.date.fromisoformat(sys.argv[2]);s=datetime.date.fromisoformat(sys.argv[3]);print(max(s,u-datetime.timedelta(days=w-1)).isoformat())" "$DAY_WINDOW" "$UNTIL" "$SINCE")"
DAYS="$(python3 -c "import datetime,sys;a=datetime.date.fromisoformat(sys.argv[1]);b=datetime.date.fromisoformat(sys.argv[2]);print('\n'.join((a+datetime.timedelta(d)).isoformat() for d in range((b-a).days+1)))" "$DAY_START" "$UNTIL")"

ROWS_FILE="$(mktemp "${TMPDIR:-/tmp}/ai-footprint-rows-XXXXXX")"
trap 'rm -f "$ROWS_FILE"' EXIT

# Invalidate the cache if the tokscale config / agent set changed; ensure the schema exists.
cache_init || true

# fetch_bucket: serve a sealed bucket from the cache, otherwise compute it via tokscale and
# store the result. Keeps the aggregation step (below) identical — it still reads TSV rows.
fetch_bucket() {
  local gran="$1" bucket="$2" rows
  if cache_enabled && rows="$(cache_get "$gran" "$bucket")"; then
    [ -n "$rows" ] && printf '%s\n' "$rows"
    return 0
  fi
  rows="$(emit_bucket "$gran" "$bucket")"
  [ -n "$rows" ] && printf '%s\n' "$rows"
  # Only pipe into cache_put when caching is on — a disabled cache_put would not drain
  # stdin, and the dangling printf would die with SIGPIPE under `set -o pipefail`.
  if cache_enabled; then
    printf '%s' "$rows" | cache_put "$gran" "$bucket"
  fi
}

for M in $MONTHS; do fetch_bucket month "$M" >> "$ROWS_FILE"; done
for D in $DAYS;   do fetch_bucket day   "$D" >> "$ROWS_FILE"; done

# --- Aggregate the rows into the report JSON --------------------------------
HOME="$HOME" TODAY="$TODAY" python3 - "$ROWS_FILE" <<'PYEOF'
import json, os, sys
from collections import defaultdict

today = os.environ["TODAY"]
year = today[:4]

# tokscale encodes a workspace path by replacing "/" with "-" (e.g. /Users/me/proj -> -Users-me-proj).
# Strip the user's home prefix for a readable project label; keep the raw label as the unique key.
home_prefix = os.environ.get("HOME", "").replace("/", "-")

def project_label(workspace):
    if not workspace or workspace == "unknown":
        return "unknown"
    label = workspace
    if home_prefix and label.startswith(home_prefix):
        label = label[len(home_prefix):]
    return label.lstrip("-") or workspace.lstrip("-") or workspace

rows = []
with open(sys.argv[1]) as f:
    for line in f:
        line = line.rstrip("\n")
        if not line:
            continue
        (gran, bucket, client, provider, model, family,
         inp, out, cr, cw, co2, water, cost, excluded, workspace) = line.split("\t")
        rows.append(dict(
            gran=gran, bucket=bucket, client=client, provider=provider,
            model=model, family=family,
            input=int(inp), output=int(out), cache_read=int(cr), cache_write=int(cw),
            co2=float(co2), water=float(water), cost=float(cost),
            excluded=int(excluded),
            workspace=(workspace or "unknown"),
            project=project_label(workspace),
        ))

monthly = [r for r in rows if r["gran"] == "month" and not r["excluded"]]
daily   = [r for r in rows if r["gran"] == "day"   and not r["excluded"]]

def tok(r):
    return r["input"] + r["output"] + r["cache_read"] + r["cache_write"]

def totals(rs):
    return dict(
        co2=round(sum(r["co2"] for r in rs), 3),
        water=round(sum(r["water"] for r in rs), 4),
        cost=round(sum(r["cost"] for r in rs), 3),
        tokens=sum(tok(r) for r in rs),
        io_tokens=sum(r["input"] + r["output"] for r in rs),
        agents=len({r["client"] for r in rs}),
        models=len({r["model"] for r in rs}),
    )

def group(rs, keyfn, label, extra=None):
    buckets = defaultdict(list)
    for r in rs:
        buckets[keyfn(r)].append(r)
    out = []
    for key, grp in buckets.items():
        row = {label: key,
               "co2": round(sum(r["co2"] for r in grp), 3),
               "water": round(sum(r["water"] for r in grp), 4),
               "cost": round(sum(r["cost"] for r in grp), 3),
               "tokens": sum(tok(r) for r in grp)}
        if extra:
            extra(row, grp)
        out.append(row)
    out.sort(key=lambda x: x["co2"], reverse=True)
    return out

months_present = sorted({r["bucket"] for r in monthly})
first_date = (months_present[0] + "-01") if months_present else ""
last_date  = today if monthly or daily else ""

data = {
    "today": totals([r for r in daily if r["bucket"] == today]),
    "year":  totals([r for r in monthly if r["bucket"].startswith(year)]),
    "all":   totals(monthly),
    "first_date": first_date,
    "last_date": last_date,
    "by_agent": group(
        monthly, lambda r: r["client"], "client",
        lambda row, grp: row.update(
            model_count=len({r["model"] for r in grp}),
            provider_count=len({r["provider"] for r in grp}),
            project_count=len({r["workspace"] for r in grp}),
            first_date=min(r["bucket"] for r in grp) + "-01",
            last_date=max(r["bucket"] for r in grp) + "-01",
        ),
    ),
    "by_project": group(
        monthly, lambda r: r["project"], "project",
        lambda row, grp: row.update(
            agent_count=len({r["client"] for r in grp}),
            model_count=len({r["model"] for r in grp}),
            top_agent=max(
                ({r["client"] for r in grp}),
                key=lambda c: sum(r["co2"] for r in grp if r["client"] == c),
            ),
        ),
    ),
    "by_provider": group(
        monthly, lambda r: r["provider"], "provider",
        lambda row, grp: row.update(
            model_count=len({r["model"] for r in grp}),
            agent_count=len({r["client"] for r in grp}),
        ),
    ),
    "by_model": group(
        monthly, lambda r: r["model"], "model",
        lambda row, grp: row.update(
            family=grp[0]["family"],
            provider=grp[0]["provider"],
            agent_count=len({r["client"] for r in grp}),
        ),
    ),
    "by_month": sorted(
        group(monthly, lambda r: r["bucket"], "month",
              lambda row, grp: row.update(
                  agent_count=len({r["client"] for r in grp}),
                  model_count=len({r["model"] for r in grp}),
                  project_count=len({r["workspace"] for r in grp}),
              )),
        key=lambda x: x["month"],
    ),
    "by_day": sorted(
        group(daily, lambda r: r["bucket"], "date",
              lambda row, grp: row.update(agent_count=len({r["client"] for r in grp}))),
        key=lambda x: x["date"], reverse=True,
    ),
}

json.dump(data, sys.stdout, ensure_ascii=False)
PYEOF
