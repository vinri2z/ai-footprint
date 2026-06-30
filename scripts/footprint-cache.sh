# footprint-cache.sh — bash glue around footprint-cache.py (the SQLite bucket cache).
#
# Sourced by footprint-data.sh. Provides:
#   cache_enabled            -> 0/1 (honours AI_FOOTPRINT_NO_CACHE)
#   cache_fingerprint        -> stdout: a string that changes when the tokscale config / agent
#                               set changes, so the cache can self-invalidate
#   cache_init               -> wipe cache if the fingerprint changed; ensure schema
#   cache_get GRAN BUCKET    -> print cached rows + return 0 on a sealed hit, else return 1
#   cache_put GRAN BUCKET    -> store rows read from stdin for this bucket
#
# Requires TODAY to be set by the caller (footprint-data.sh resolves it once).
#
# bash 3.2 compatible: no associative arrays, no mapfile.

CACHE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_PY="${CACHE_DIR}/footprint-cache.py"

cache_enabled() {
  [ "${AI_FOOTPRINT_NO_CACHE:-0}" = "1" ] && return 1
  [ -f "$CACHE_PY" ] || return 1
  return 0
}

# Fingerprint = sha256 of: tokscale settings.json + the sorted set of agents that have data
# + data/factors.json. It changes — and the cache self-wipes — when:
#   • an agent is added to the tokscale config, or a new agent shows up with sessions, OR
#   • the CO2/water factors change (cached buckets hold *computed* CO2/water, so a factor edit
#     must invalidate them to keep "edit a factor, next report reflects it" true).
# Names only for agents (never message counts — those change constantly and would defeat the
# cache). Falls back to a checksum if no sha tooling is available (cache still works).
cache_fingerprint() {
  local settings="${TOKSCALE_SETTINGS:-$HOME/.config/tokscale/settings.json}"
  local factors="${CACHE_DIR}/../data/factors.json"
  local settings_blob factors_blob agents

  settings_blob=""
  [ -f "$settings" ] && settings_blob="$(cat "$settings" 2>/dev/null)"
  factors_blob=""
  [ -f "$factors" ] && factors_blob="$(cat "$factors" 2>/dev/null)"

  agents="$(run_tokscale clients --json 2>/dev/null \
    | jq -r '[.clients[]? | select((.messageCount // 0) > 0) | .client] | sort | join(",")' 2>/dev/null)"

  printf '%s\n---\n%s\n---\n%s' "$settings_blob" "$agents" "$factors_blob" | _cache_hash
}

_cache_hash() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    # No hashing tool: fall back to a stable-but-opaque token so init still succeeds.
    cksum | awk '{print $1"-"$2}'
  fi
}

cache_init() {
  cache_enabled || return 0
  python3 "$CACHE_PY" init "$(cache_fingerprint)" >/dev/null 2>&1 || return 1
}

cache_get() {
  cache_enabled || return 1
  python3 "$CACHE_PY" get "$1" "$2" "$TODAY" 2>/dev/null
}

cache_put() {
  cache_enabled || return 0
  python3 "$CACHE_PY" put "$1" "$2" "$TODAY" >/dev/null 2>&1 || true
}
