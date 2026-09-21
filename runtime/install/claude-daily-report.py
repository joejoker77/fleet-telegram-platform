#!/usr/bin/python3
"""Daily activity report for the claude-fleet-monaco bot fleet.

Counts the turns a person actually took with their assistant, split by where they
took them — Telegram, or the Claude App — and sends one Telegram DM per recipient.

WHAT CHANGED ON 2026-09-21. This used to count inbound Telegram messages only, read
from the exported channel transcripts. Work done in the App was invisible: `denis`
was reported at 9 messages for the week while he had had 533 turns in the App, and
597 of the firm's 2230 turns that week were missing from the report entirely. The
counting now comes from the transcripts Claude Code writes for every turn whatever
drove it (see claude-usage-core.py), so both columns come from one source.

The "exporter stale" caveat went with it: there is no longer an exporter between the
work and the number, so an active bot can no longer be rendered as an idle one.

Reads counts only — no conversation content is ever put in the report.

Cron: /etc/cron.d/claude-daily-report  (20:00 UTC daily, as root)
Source of truth: fleet-telegram-platform/runtime/install/claude-daily-report.py
Deployed to /usr/local/bin/claude_daily_report.py; counting core at
/usr/local/lib/claude-usage-core.py. NO LLM call — this is a timer.
"""

import datetime as dt
import importlib.util
import json
import sys
import urllib.error
import urllib.parse
import urllib.request

# (label, chat_id, path to the .env holding that bot's TELEGRAM_BOT_TOKEN)
# A Telegram bot can only DM someone who has already started it, so each
# recipient is messaged by the bot they personally talk to.
RECIPIENTS = [
    ("dmitrii", "99590176",
     "/home/dmitriirudenko/.claude/channels/telegram-dmitriirudenko/.env"),
    ("tom", "5587173276",
     "/home/tonysoprano1337/.claude/channels/telegram-tonysoprano1337/.env"),
]
WINDOW_DAYS = 7
SERVER_NAME = "claude-fleet-monaco"
CORE_PATH = "/usr/local/lib/claude-usage-core.py"


def log(msg):
    print("[%s] %s" % (dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S"), msg),
          flush=True)


def load_core():
    spec = importlib.util.spec_from_file_location("claude_usage_core", CORE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("counting core missing at %s" % CORE_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def render(rows, title):
    tg_today = sum(r["tg_today"] for r in rows)
    app_today = sum(r["app_today"] for r in rows)
    tg_week = sum(r["tg_week"] for r in rows)
    app_week = sum(r["app_week"] for r in rows)

    out = ["<b>%s</b>  —  today %d (%d Telegram, %d App), %d days %d (%d Telegram, %d App)"
           % (title, tg_today + app_today, tg_today, app_today,
              WINDOW_DAYS, tg_week + app_week, tg_week, app_week)]
    # Widths fit the longest tenant name on this host (19) and keep the whole row
    # inside ~41 characters, which is what a phone shows in a <pre> block without
    # wrapping — a wrapped table is unreadable and this is read on a phone.
    out.append("<pre>%-19s %9s %11s" % ("", "today", "%d days" % WINDOW_DAYS))
    out.append("%-19s %4s %4s %5s %5s" % ("bot", "tg", "app", "tg", "app"))
    for r in sorted(rows, key=lambda r: (-(r["tg_today"] + r["app_today"]),
                                         -(r["tg_week"] + r["app_week"]), r["name"])):
        line = "%-19s %4d %4d %5d %5d" % (
            r["name"], r["tg_today"], r["app_today"], r["tg_week"], r["app_week"])
        if r["problem"]:
            line += "  ! %s" % r["problem"][:34]
        out.append(line)
    out.append("</pre>")

    idle = [r["name"] for r in rows
            if not r["problem"] and r["tg_week"] + r["app_week"] == 0]
    if idle:
        out.append("Silent all week: %s" % ", ".join(idle))
    broken = ["%s (%s)" % (r["name"], r["problem"]) for r in rows if r["problem"]]
    if broken:
        out.append("<b>Needs a look: %s</b>" % ", ".join(broken))
    return "\n".join(out)


def bot_token(path):
    """Read a bot token from a channel state dir. Never logged or echoed."""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line.startswith("export "):
                    line = line[7:]
                if "=" in line:
                    k, v = line.split("=", 1)
                    if k.strip() in ("TELEGRAM_BOT_TOKEN", "BOT_TOKEN"):
                        return v.strip().strip('"').strip("'")
    except OSError as e:
        log("cannot read bot token file: %s" % e)
    return None


def send_one(label, chat_id, env_path, text):
    tok = bot_token(env_path)
    if not tok:
        log("[%s] no bot token in %s - NOT sent" % (label, env_path))
        return False
    data = urllib.parse.urlencode({
        "chat_id": chat_id,
        "text": text,
        "parse_mode": "HTML",
        "disable_web_page_preview": "true",
    }).encode()
    req = urllib.request.Request(
        "https://api.telegram.org/bot%s/sendMessage" % tok, data=data)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            body = json.loads(r.read().decode())
        log("[%s] sent, message_id=%s"
            % (label, body.get("result", {}).get("message_id")))
        return True
    except urllib.error.HTTPError as e:
        log("[%s] telegram HTTP %s: %s" % (label, e.code, e.read()[:300]))
    except Exception as e:
        log("[%s] telegram send failed: %s" % (label, e))
    return False


def send(text):
    """Deliver to every recipient. One failure must not hide the others."""
    ok = True
    for label, chat_id, env_path in RECIPIENTS:
        if not send_one(label, chat_id, env_path, text):
            ok = False
    return ok


def main():
    day = dt.datetime.now(dt.timezone.utc).strftime("%a %d %b %Y")
    parts = ["<b>Claude bot activity — %s</b>" % day]
    try:
        rows = load_core().collect(WINDOW_DAYS)
    except Exception as exc:
        # A section that cannot be collected must SAY SO — never let silence read as zero.
        log("collection failed: %s" % exc)
        rows = []
        parts.append("<b>%s: counting failed (%s) — these numbers are missing, not zero.</b>"
                     % (SERVER_NAME, str(exc)[:120]))
    if rows:
        parts.append(render(rows, SERVER_NAME))
    elif len(parts) == 1:
        parts.append("<b>%s: no bots found — collection failed.</b>" % SERVER_NAME)
    text = "\n\n".join(parts)
    if "--dry-run" in sys.argv:
        print(text)
        return 0
    return 0 if send(text) else 1


if __name__ == "__main__":
    sys.exit(main())
