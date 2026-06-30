#!/usr/bin/env python3
"""footprint-cache.py — SQLite cache for ai-footprint's per-bucket tokscale rows.

footprint-data.sh computes one set of TSV rows per time bucket (a month or a day) by
querying tokscale and applying the CO2/water factors. Those rows are expensive to produce
(each bucket is a separate `npx tokscale` invocation) but, for buckets that lie wholly in
the past, they never change. This cache stores the computed rows so closed buckets are read
from SQLite instead of re-querying tokscale on every report.

Caching unit: one bucket = one (gran, bucket) pair, holding zero or more TSV rows. A bucket
is "sealed" (safe to serve from cache) when it can no longer change:
  • month bucket  -> sealed once its month is strictly before the current month
  • day bucket    -> sealed once its date is before today AND it was fetched on a later day
Unsealed buckets (current month, today, days fetched the same day) always miss so the caller
re-queries tokscale — this is what makes refreshes incremental: only live/new buckets hit
tokscale, every sealed bucket is reused.

Invalidation: the caller passes a fingerprint derived from the tokscale config (settings.json
+ the set of agents tokscale can see). When it changes — e.g. an agent is added — the whole
cache is wiped so historical buckets are recomputed with the new agent set.

Commands (one tokscale TSV row per line on stdin/stdout):
  init <fingerprint>            ensure schema; wipe everything if the fingerprint changed
  get  <gran> <bucket> <today>  print cached rows + exit 0 if sealed & present, else exit 1
  put  <gran> <bucket> <today>  replace the bucket's rows from stdin, mark it fetched today
  info                          print cache stats to stderr (debugging)
"""
import os
import sqlite3
import sys

SCHEMA_VERSION = "1"

# TSV column order produced by footprint-data.sh's emit_bucket (gran/bucket are columns 1-2).
ROW_COLS = [
    "gran", "bucket", "client", "provider", "model", "family",
    "input", "output", "cache_read", "cache_write",
    "co2", "water", "cost", "excluded", "workspace",
]


def db_path() -> str:
    explicit = os.environ.get("AI_FOOTPRINT_DB")
    if explicit:
        return explicit
    cache_home = os.environ.get("XDG_CACHE_HOME") or os.path.join(
        os.path.expanduser("~"), ".cache"
    )
    return os.path.join(cache_home, "ai-footprint", "footprint.db")


def connect() -> sqlite3.Connection:
    path = db_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    conn = sqlite3.connect(path)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute(
        "CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT)"
    )
    conn.execute(
        "CREATE TABLE IF NOT EXISTS buckets("
        "  gran TEXT, bucket TEXT, fetched_date TEXT,"
        "  PRIMARY KEY (gran, bucket))"
    )
    conn.execute(
        "CREATE TABLE IF NOT EXISTS rows("
        "  gran TEXT, bucket TEXT, client TEXT, provider TEXT, model TEXT,"
        "  family TEXT, input INTEGER, output INTEGER, cache_read INTEGER,"
        "  cache_write INTEGER, co2 REAL, water REAL, cost REAL,"
        "  excluded INTEGER, workspace TEXT)"
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_rows_bucket ON rows(gran, bucket)"
    )
    return conn


def get_meta(conn, key, default=None):
    row = conn.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
    return row[0] if row else default


def set_meta(conn, key, value):
    conn.execute(
        "INSERT INTO meta(key, value) VALUES(?, ?) "
        "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        (key, value),
    )


def wipe(conn):
    conn.execute("DELETE FROM rows")
    conn.execute("DELETE FROM buckets")


def cmd_init(fingerprint: str) -> int:
    conn = connect()
    try:
        if get_meta(conn, "schema_version") != SCHEMA_VERSION:
            wipe(conn)
            set_meta(conn, "schema_version", SCHEMA_VERSION)
            set_meta(conn, "fingerprint", "")
        if get_meta(conn, "fingerprint", "") != fingerprint:
            wipe(conn)
            set_meta(conn, "fingerprint", fingerprint)
        conn.commit()
    finally:
        conn.close()
    return 0


def is_sealed(gran: str, bucket: str, fetched_date: str, today: str) -> bool:
    if gran == "month":
        # bucket is YYYY-MM; sealed once strictly before the current month.
        return bucket < today[:7]
    # day bucket (YYYY-MM-DD): sealed only if the day is over AND it was already
    # complete when fetched (fetched on a strictly later date).
    return bucket < today and fetched_date > bucket


def cmd_get(gran: str, bucket: str, today: str) -> int:
    conn = connect()
    try:
        row = conn.execute(
            "SELECT fetched_date FROM buckets WHERE gran=? AND bucket=?",
            (gran, bucket),
        ).fetchone()
        if not row:
            return 1  # never fetched
        if not is_sealed(gran, bucket, row[0], today):
            return 1  # live bucket — force a refetch
        cur = conn.execute(
            "SELECT " + ", ".join(ROW_COLS) + " FROM rows WHERE gran=? AND bucket=?",
            (gran, bucket),
        )
        out = sys.stdout
        for r in cur:
            out.write("\t".join("" if v is None else str(v) for v in r))
            out.write("\n")
        return 0
    finally:
        conn.close()


def cmd_put(gran: str, bucket: str, today: str) -> int:
    conn = connect()
    try:
        conn.execute("DELETE FROM rows WHERE gran=? AND bucket=?", (gran, bucket))
        placeholders = ", ".join(["?"] * len(ROW_COLS))
        for line in sys.stdin:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) != len(ROW_COLS):
                # Skip malformed lines rather than poison the cache.
                continue
            conn.execute(
                "INSERT INTO rows(" + ", ".join(ROW_COLS) + ") VALUES(" + placeholders + ")",
                parts,
            )
        conn.execute(
            "INSERT INTO buckets(gran, bucket, fetched_date) VALUES(?, ?, ?) "
            "ON CONFLICT(gran, bucket) DO UPDATE SET fetched_date=excluded.fetched_date",
            (gran, bucket, today),
        )
        conn.commit()
    finally:
        conn.close()
    return 0


def cmd_info() -> int:
    conn = connect()
    try:
        nb = conn.execute("SELECT COUNT(*) FROM buckets").fetchone()[0]
        nr = conn.execute("SELECT COUNT(*) FROM rows").fetchone()[0]
        fp = get_meta(conn, "fingerprint", "")
        sys.stderr.write(
            f"ai-footprint cache: {db_path()}\n"
            f"  buckets={nb} rows={nr} fingerprint={fp[:16]}…\n"
        )
    finally:
        conn.close()
    return 0


def main(argv) -> int:
    if not argv:
        sys.stderr.write("usage: footprint-cache.py {init|get|put|info} ...\n")
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "init":
        return cmd_init(rest[0] if rest else "")
    if cmd == "get":
        return cmd_get(rest[0], rest[1], rest[2])
    if cmd == "put":
        return cmd_put(rest[0], rest[1], rest[2])
    if cmd == "info":
        return cmd_info()
    sys.stderr.write(f"unknown command: {cmd}\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
