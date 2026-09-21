#!/usr/bin/env python3
"""claude-usage-core — how much each tenant actually used their assistant.

WHY THIS EXISTS. The daily activity report counted inbound TELEGRAM messages, taken
from the exported channel transcripts. Every session driven from the Claude App was
therefore invisible, and the people who work that way read as idle. On 2026-09-21 the
firm host showed `denis` at 9 messages for the week while he had had 533 turns in the
App — the heaviest user on the box, reported as the quietest. That is the bug this
module fixes, by counting from the source both channels share.

WHERE THE TRUTH IS. Claude Code writes every turn to ~/.claude/projects/**/*.jsonl,
whatever drove it — Telegram, the App, or someone typing in the terminal. The channel
exports under ~/.claude/channels/ are a rendering of the Telegram slice only, so they
can never see App work. Counting from the JSONL also removes the old "exporter stale"
caveat: there is no longer an exporter between the work and the number.

TELLING THE CHANNELS APART. A Telegram turn arrives as a user entry whose content holds
`<channel source="plugin:telegram:telegram" ...>`. Everything else a person typed is
App-or-terminal. Two traps, both hit during development:
  * Telegram inbound entries are flagged `isMeta`, so an isMeta filter placed before the
    channel test silently zeroes the whole Telegram column;
  * the user slot also carries tool results and harness injections (task notifications,
    system reminders, slash-command echoes, session restores). Counting those inflates
    App usage by roughly a tenth. Both are filtered below.

NOT AN LLM CALL. This reads files and counts. Safe to run from a timer — see the
platform rule forbidding scheduled model calls.
"""

import datetime as dt
import glob
import json
import os
import time

WINDOW_DAYS = 7
# A file untouched for longer than the window cannot hold a turn inside it. Two days of
# slack covers clock skew and a session written just before the boundary.
MTIME_SLACK_DAYS = WINDOW_DAYS + 2

TELEGRAM_MARK = "plugin:telegram:telegram"

# Text that appears in the user slot but that no person typed.
INJECTED = (
    "<task-notification>",
    "<system-reminder>",
    "[SYSTEM]",
    "<local-command",
    "<command-name>",
    "<command-message>",
    "<user-memory-input>",
    "Caveat: The messages below",
    "⟪ SESSION-RESTORE",
    "⟪SESSION-RESTORE",
)


def _text_of(content):
    """The human-visible text of a user message, for injection matching."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "text":
                parts.append(block.get("text") or "")
            elif block.get("type") == "image":
                parts.append("[image]")
        return "\n".join(parts)
    return ""


def classify(entry):
    """'telegram', 'app', or None for anything that is not a human turn."""
    if entry.get("type") != "user":
        return None
    content = entry.get("message", {}).get("content")
    if isinstance(content, list) and any(
            isinstance(b, dict) and b.get("type") == "tool_result" for b in content):
        return None
    raw = content if isinstance(content, str) else json.dumps(content)
    # Before the isMeta test, deliberately: Telegram inbound is flagged isMeta.
    if TELEGRAM_MARK in raw:
        return "telegram"
    if entry.get("isMeta"):
        return None
    text = _text_of(content).lstrip()
    if not text:
        return None
    if any(text.startswith(p) for p in INJECTED):
        return None
    return "app"


def tenants():
    """Everyone with a Claude home on this host, whichever host it is."""
    if os.path.isdir("/etc/claude-role"):
        names = os.listdir("/etc/claude-role")
    else:
        names = [n for n in os.listdir("/home")
                 if os.path.isdir("/home/%s/.claude" % n)]
    return sorted(names)


def count_user(user, window_days=WINDOW_DAYS, now=None):
    """(tg_today, app_today, tg_week, app_week, last_ts_iso, problem) for one tenant."""
    now = now or dt.datetime.now(dt.timezone.utc)
    today = now.date().isoformat()
    window = {(now.date() - dt.timedelta(days=i)).isoformat() for i in range(window_days)}
    cutoff = time.time() - MTIME_SLACK_DAYS * 86400

    base = "/home/%s/.claude/projects" % user
    if not os.path.isdir(base):
        return 0, 0, 0, 0, None, None

    counts = {"telegram": {}, "app": {}}
    last = None
    problem = None
    try:
        files = glob.glob(base + "/**/*.jsonl", recursive=True)
    except OSError as exc:
        return 0, 0, 0, 0, None, "transcripts unreadable: %s" % exc

    for path in files:
        try:
            if os.path.getsize(path) == 0 or os.path.getmtime(path) < cutoff:
                continue
        except OSError:
            continue
        try:
            handle = open(path, "r", encoding="utf-8", errors="replace")
        except OSError as exc:
            problem = problem or "transcript unreadable: %s" % exc
            continue
        with handle:
            for line in handle:
                # Cheap reject first: most lines are assistant output and tool results.
                if '"user"' not in line:
                    continue
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                kind = classify(entry)
                if kind is None:
                    continue
                stamp = entry.get("timestamp") or ""
                day = stamp[:10]
                if day not in window:
                    continue
                counts[kind][day] = counts[kind].get(day, 0) + 1
                if last is None or stamp > last:
                    last = stamp

    return (
        counts["telegram"].get(today, 0),
        counts["app"].get(today, 0),
        sum(counts["telegram"].values()),
        sum(counts["app"].values()),
        last,
        problem,
    )


def collect(window_days=WINDOW_DAYS):
    """One row per tenant: dicts, so the same shape survives a trip over ssh."""
    now = dt.datetime.now(dt.timezone.utc)
    rows = []
    for user in tenants():
        tg_t, app_t, tg_w, app_w, last, problem = count_user(user, window_days, now)
        rows.append({
            "name": user,
            "tg_today": tg_t, "app_today": app_t,
            "tg_week": tg_w, "app_week": app_w,
            "last_ts": last, "problem": problem,
        })
    return rows


if __name__ == "__main__":
    print(json.dumps(collect()))
