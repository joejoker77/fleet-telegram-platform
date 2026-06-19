#!/usr/bin/env python3
"""session_indexer.py — incrementally index this bot's session_*.txt logs
into a SQLite FTS5 database for fast full-text search.

Run by per-user cron every few minutes.  Skips files unchanged since the
last run (tracked by mtime+size in a side table).  Re-indexes rotated
files on first sight.  Cheap to run repeatedly — does nothing if no logs
have changed.

  Source dir : ~/.claude/channels/telegram-<user>/logs/
  Index file : <source dir>/.index/session_index.db
"""

from __future__ import annotations

import os
import sqlite3
import sys
import time
from pathlib import Path

CHUNK_LINES = 50  # how many log lines to glue together per FTS5 row


def find_log_dir() -> Path:
    home = Path(os.path.expanduser("~"))
    user = home.name
    candidate = home / ".claude" / "channels" / f"telegram-{user}" / "logs"
    if not candidate.is_dir():
        sys.stderr.write(f"session_indexer: log dir not found: {candidate}\n")
        sys.exit(0)
    return candidate


def open_db(db_path: Path) -> sqlite3.Connection:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path))
    conn.executescript(
        """
        CREATE VIRTUAL TABLE IF NOT EXISTS sessions USING fts5(
          filename, chunk_no UNINDEXED, ts UNINDEXED, body,
          tokenize='unicode61 remove_diacritics 2'
        );
        CREATE TABLE IF NOT EXISTS file_state (
          filename TEXT PRIMARY KEY,
          mtime REAL NOT NULL,
          size INTEGER NOT NULL,
          last_chunk INTEGER NOT NULL DEFAULT 0
        );
        """
    )
    return conn


def index_file(conn: sqlite3.Connection, path: Path) -> tuple[int, bool]:
    """Add new content from `path` to the index.  Returns (rows_added, did_work)."""
    stat = path.stat()
    cur = conn.execute(
        "SELECT mtime, size, last_chunk FROM file_state WHERE filename = ?",
        (path.name,),
    )
    row = cur.fetchone()
    prev_size = row[1] if row else 0
    prev_chunk = row[2] if row else 0

    if row and stat.st_mtime == row[0] and stat.st_size == prev_size:
        return 0, False

    if stat.st_size < prev_size:
        conn.execute("DELETE FROM sessions WHERE filename = ?", (path.name,))
        prev_chunk = 0
        prev_size = 0

    with path.open("r", encoding="utf-8", errors="replace") as f:
        f.seek(prev_size)
        leftover = f.read()

    if not leftover.strip():
        conn.execute(
            "INSERT OR REPLACE INTO file_state(filename, mtime, size, last_chunk) "
            "VALUES (?, ?, ?, ?)",
            (path.name, stat.st_mtime, stat.st_size, prev_chunk),
        )
        return 0, True

    lines = leftover.splitlines()
    rows_added = 0
    chunk_no = prev_chunk
    current_ts = ""
    for i in range(0, len(lines), CHUNK_LINES):
        block = lines[i : i + CHUNK_LINES]
        for ln in block:
            if ln.startswith("===== ") and ln.endswith(" ====="):
                current_ts = ln[6:-6]
        body = "\n".join(block)
        chunk_no += 1
        conn.execute(
            "INSERT INTO sessions(filename, chunk_no, ts, body) VALUES (?, ?, ?, ?)",
            (path.name, chunk_no, current_ts, body),
        )
        rows_added += 1

    conn.execute(
        "INSERT OR REPLACE INTO file_state(filename, mtime, size, last_chunk) "
        "VALUES (?, ?, ?, ?)",
        (path.name, stat.st_mtime, stat.st_size, chunk_no),
    )
    return rows_added, True


def main() -> int:
    log_dir = find_log_dir()
    db_path = log_dir / ".index" / "session_index.db"

    conn = open_db(db_path)
    try:
        total_added = 0
        files_touched = 0
        for path in sorted(log_dir.glob("session_*.txt")):
            added, did_work = index_file(conn, path)
            total_added += added
            if did_work:
                files_touched += 1
        conn.commit()

        if files_touched:
            sys.stdout.write(
                f"session_indexer: {time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())} "
                f"files_touched={files_touched} rows_added={total_added} db={db_path}\n"
            )
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
