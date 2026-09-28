#!/usr/bin/env python3
"""Claude Code status line that records the tenant's usage limits for compact-governor.

Claude Code pipes a JSON document to the status line command after every assistant
message. It already carries the account's 5-hour and weekly limits (percent used and
reset time) — the same numbers Claude Code shows in /usage — so recording them here
costs no request of our own to Anthropic. That was the hard requirement (Vitaliy,
2026-09-25: any ban risk for the firm is unacceptable).

Writes ~/.claude/usage-snapshot.json atomically and prints nothing, so the lawyer's
screen does not change. Never raises: a broken status line must not bother the session.
"""
import json
import os
import sys
import tempfile
import time


def main():
    try:
        d = json.load(sys.stdin)
    except Exception:
        return
    rl = d.get("rate_limits") or {}
    snap = {"ts": int(time.time()), "session_id": d.get("session_id")}
    for key in ("five_hour", "seven_day"):
        w = rl.get(key) or {}
        try:
            snap[key] = {"used_percentage": float(w["used_percentage"]),
                         "resets_at": int(w["resets_at"])}
        except (KeyError, TypeError, ValueError):
            pass
    cw = d.get("context_window") or {}
    if isinstance(cw.get("total_input_tokens"), int):
        snap["context_tokens"] = cw["total_input_tokens"]
    if "five_hour" not in snap and "seven_day" not in snap:
        return  # nothing worth recording; keep the previous snapshot
    home = os.path.expanduser("~/.claude")
    fd, tmp = tempfile.mkstemp(dir=home, prefix=".usage-snapshot.")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(snap, f)
        os.chmod(tmp, 0o644)
        os.replace(tmp, os.path.join(home, "usage-snapshot.json"))
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
