#!/usr/bin/env python3
"""tenant-logcaps — keep Claude's own logs inside each tenant's home from filling
the disk.

Three things under /home/<user>/.claude grow with no ceiling at all:

  projects/**/*.jsonl          raw session transcripts  (~24 GB fleet-wide)
  channels/*/logs/*.log.N      rotated tmux pane dumps  (~6 GB fleet-wide)
  channels/*/inbox/*           files people sent the bot on Telegram

The transcripts are already summarised elsewhere.  transcript-exporter turns
every .jsonl into a compact session_<utc>_<uuid8>.txt under
channels/<ch>/logs/sessions/, and session_indexer feeds those into the FTS5
database that `session-search` reads.  So deleting an old .jsonl costs no
searchable history -- the only thing lost is resuming a session that old.

Which is why this job deletes a .jsonl ONLY when the exporter's own state file
says it was exported whole (same size, same mtime) and the exported .txt is
still on disk.  Anything it cannot prove was exported, it keeps and counts.

Never touched, at any age:
  * the live channels/<ch>/logs/claude-pane.log  (logrotate owns that one)
  * logs/.index/            the search database
  * logs/sessions/*.txt     the exported transcripts -- the thing we keep
  * logs/session_current.txt
  * every file at the channel root: .env, access.json, bot.pid, relogin-token,
    last_chat.json ... that is the channel's identity, not a log.

  tenant-logcaps.py                 report what would go (dry run -- the default)
  tenant-logcaps.py --apply         delete it
  tenant-logcaps.py --user vitaliy  one tenant only
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
import time
from pathlib import Path

PROJECTS_DAYS = 30
CHANNELS_DAYS = 14
REPORT_DIR = Path("/var/log/tenant-logcaps")

# Live state under logs/ that never ages out, whatever its mtime says.
KEEP_LOG_NAMES = {"claude-pane.log", "session_current.txt"}


def load_export_state(home: Path) -> dict[str, dict]:
    """Every .jsonl the exporter has finished with, keyed by absolute path."""
    state: dict[str, dict] = {}
    for st_path in home.glob(".claude/channels/*/logs/sessions/.export_state.json"):
        try:
            with st_path.open() as fh:
                blob = json.load(fh)
        except (OSError, ValueError):
            continue
        if not isinstance(blob, dict):
            continue
        out_dir = st_path.parent
        for src, rec in blob.items():
            if isinstance(rec, dict) and rec.get("out"):
                rec = dict(rec)
                rec["_out_path"] = out_dir / rec["out"]
                state[src] = rec
    return state


def exported_whole(path: Path, st: os.stat_result, state: dict[str, dict]) -> bool:
    """True only if this exact version of the transcript is already summarised."""
    rec = state.get(str(path))
    if not rec:
        return False
    if rec.get("size") != st.st_size:
        return False
    try:
        recorded = float(rec.get("mtime", 0))
    except (TypeError, ValueError):
        return False
    if abs(recorded - st.st_mtime) > 1.0:
        return False
    out = rec.get("_out_path")
    return bool(out and out.exists())


def is_dir(path: Path) -> bool:
    """Path.is_dir() that says "no" instead of raising on an unreadable parent."""
    try:
        return path.is_dir()
    except OSError:
        return False


def prune_empty_dirs(root: Path) -> int:
    """Drop directories left empty under each project, never the project itself."""
    removed = 0
    try:
        projects = sorted(p for p in root.iterdir() if p.is_dir())
    except OSError:
        return 0
    for project in projects:
        for dirpath, dirnames, filenames in os.walk(project, topdown=False):
            here = Path(dirpath)
            if here == project or dirnames or filenames:
                continue
            try:
                here.rmdir()
                removed += 1
            except OSError:
                pass
    return removed


def sweep_home(home: Path, now: float, args) -> dict:
    res = {
        "user": home.name,
        "projects_bytes": 0, "projects_files": 0, "projects_kept_unexported": 0,
        "panelogs_bytes": 0, "panelogs_files": 0,
        "inbox_bytes": 0, "inbox_files": 0,
        "dirs_removed": 0,
        "errors": [],
    }
    projects_cutoff = now - args.projects_days * 86400
    channels_cutoff = now - args.channels_days * 86400

    def drop(path: Path, size: int, bucket: str) -> None:
        if args.apply:
            try:
                path.unlink()
            except OSError as exc:
                res["errors"].append(f"{path}: {exc}")
                return
        res[f"{bucket}_bytes"] += size
        res[f"{bucket}_files"] += 1

    # 1. raw transcripts, but only the ones already summarised
    projects = home / ".claude" / "projects"
    if is_dir(projects):
        state = load_export_state(home)
        for path in projects.rglob("*.jsonl"):
            if not path.is_file():
                continue
            try:
                st = path.lstat()
            except OSError:
                continue
            if st.st_mtime >= projects_cutoff:
                continue
            if not exported_whole(path, st, state):
                res["projects_kept_unexported"] += 1
                continue
            drop(path, st.st_size, "projects")
        if args.apply:
            res["dirs_removed"] = prune_empty_dirs(projects)

    channels = home / ".claude" / "channels"
    if is_dir(channels):
        # 2. rotated pane dumps -- the live log belongs to logrotate, not to us
        for logs in channels.glob("*/logs"):
            if not is_dir(logs):
                continue
            for path in sorted(logs.iterdir()):
                if not path.is_file() or path.name in KEEP_LOG_NAMES:
                    continue
                if not path.name.startswith("claude-pane.log."):
                    continue
                try:
                    st = path.lstat()
                except OSError:
                    continue
                if st.st_mtime < channels_cutoff:
                    drop(path, st.st_size, "panelogs")

        # 3. attachments people sent the bot
        for inbox in channels.glob("*/inbox"):
            if not is_dir(inbox):
                continue
            for path in sorted(inbox.iterdir()):
                if not path.is_file():
                    continue
                try:
                    st = path.lstat()
                except OSError:
                    continue
                if st.st_mtime < channels_cutoff:
                    drop(path, st.st_size, "inbox")

    res["total_bytes"] = res["projects_bytes"] + res["panelogs_bytes"] + res["inbox_bytes"]
    return res


def human(n: int) -> str:
    return f"{n / 1e9:.2f} GB" if n >= 1e9 else f"{n / 1e6:.0f} MB"


def main() -> int:
    ap = argparse.ArgumentParser(description="Cap Claude's own logs in tenant homes.")
    ap.add_argument("--apply", action="store_true", help="actually delete (default: dry run)")
    ap.add_argument("--root", default="/home", help="where the tenant homes are")
    ap.add_argument("--user", action="append", help="limit to this tenant (repeatable)")
    ap.add_argument("--projects-days", type=int, default=PROJECTS_DAYS)
    ap.add_argument("--channels-days", type=int, default=CHANNELS_DAYS)
    ap.add_argument("--json", action="store_true", help="machine-readable report on stdout")
    args = ap.parse_args()

    root = Path(args.root)
    if not root.is_dir():
        print(f"no such directory: {root}", file=sys.stderr)
        return 1

    homes = sorted(p for p in root.iterdir() if is_dir(p) and not p.is_symlink())
    if args.user:
        wanted = set(args.user)
        homes = [h for h in homes if h.name in wanted]

    now = time.time()
    rows = []
    for home in homes:
        try:
            rows.append(sweep_home(home, now, args))
        except OSError as exc:
            rows.append({"user": home.name, "total_bytes": 0, "projects_files": 0,
                         "panelogs_files": 0, "inbox_files": 0,
                         "projects_kept_unexported": 0, "errors": [f"{home}: {exc}"]})
    rows = [r for r in rows if r["total_bytes"] or r["errors"]]
    rows.sort(key=lambda r: r["total_bytes"], reverse=True)

    report = {
        "ran": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "mode": "apply" if args.apply else "dry-run",
        "projects_days": args.projects_days,
        "channels_days": args.channels_days,
        "freed_bytes": sum(r["total_bytes"] for r in rows),
        "tenants": rows,
    }

    if args.json:
        json.dump(report, sys.stdout, indent=1)
        print()
    else:
        verb = "freed" if args.apply else "would free"
        print(f"tenant-logcaps {report['mode']}: transcripts older than "
              f"{args.projects_days}d, channel logs older than {args.channels_days}d")
        for r in rows:
            extra = (f"  [kept {r['projects_kept_unexported']} not-yet-exported]"
                     if r["projects_kept_unexported"] else "")
            print(f"  {r['user']:<24} {human(r['total_bytes']):>9}"
                  f"   transcripts {r['projects_files']:>5}"
                  f"  panelogs {r['panelogs_files']:>3}"
                  f"  inbox {r['inbox_files']:>5}{extra}")
        print(f"  {'TOTAL':<24} {human(report['freed_bytes']):>9}  {verb}")
        for r in rows:
            for e in r["errors"]:
                print(f"  ERROR {e}", file=sys.stderr)

    if args.apply:
        try:
            REPORT_DIR.mkdir(parents=True, exist_ok=True)
            stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%d-%H%M%S")
            with (REPORT_DIR / f"run-{stamp}.json").open("w") as fh:
                json.dump(report, fh, indent=1)
        except OSError as exc:
            print(f"could not write report: {exc}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
