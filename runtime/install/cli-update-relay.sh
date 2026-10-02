#!/usr/bin/env python3
"""cli-update-relay — turn new cc-cli-update events into one Telegram message.

WHY. `cc-cli-update` appends a JSON line to /var/lib/fleet/cli-update.events for every
outcome (seeded, canary-ok, canary-failed, rolled-out, rolled-back) and says nothing else.
Until now the admin learned about a rollout only by reading that file. This relay is the
delivery half: it reads the lines written since its last run and sends them, once, to the
admin's own Telegram bot. Nothing is interpreted and NO model is called — the `text` field
written by cc-cli-update is forwarded verbatim. A run with no new lines sends nothing, so a
quiet fleet stays quiet and a message always means something actually happened.

It used to run on the operator's own host and pull this file over ssh. It now runs here,
beside the file it reads.

  cli-update-relay              send anything new, remember how far it got
  cli-update-relay --dry-run    print what would be sent, change nothing
  cli-update-relay --to USER    send to a different admin tenant's bot
  cli-update-relay --all        ignore the offset and consider every event
"""
import argparse
import json
import os
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timezone

HOME_ROOT = os.environ.get("FLEET_HOME_ROOT", "/home")
EVENTS = os.environ.get("FLEET_CLI_UPDATE_EVENTS", "/var/lib/fleet/cli-update.events")
STATE_FILE = os.environ.get("FLEET_CLI_RELAY_STATE", "/var/lib/fleet/cli-update-relay.state")
CONF = "/etc/claudeapp/cli-update-relay.env"
MAX_EVENTS = 20          # one message; older lines stay in the file for anyone reading it


def load_conf() -> None:
    """Optional host config; shell-style KEY=value, read before anything uses it."""
    try:
        with open(CONF, encoding="utf8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())
    except FileNotFoundError:
        return


def bot_credentials(admin: str) -> tuple[str, str]:
    """(token, chat_id) for the admin's own bot — a bot may only message who started it."""
    base = os.path.join(HOME_ROOT, admin, ".claude", "channels", f"telegram-{admin}")
    token = ""
    with open(os.path.join(base, ".env"), encoding="utf8") as fh:
        for line in fh:
            if line.startswith("TELEGRAM_BOT_TOKEN="):
                token = line.split("=", 1)[1].strip()
    chat = ""
    try:
        with open(os.path.join(base, "access.json"), encoding="utf8") as fh:
            allow = json.load(fh).get("allowFrom") or []
        chat = str(allow[0]) if allow else ""
    except (OSError, ValueError, IndexError):
        pass
    if not chat:
        with open(os.path.join(base, "last_chat.json"), encoding="utf8") as fh:
            chat = str(json.load(fh).get("chat_id") or "")
    if not token or not chat:
        raise SystemExit(f"cli-update-relay: no bot token / chat id for {admin}")
    return token, chat


def send(token: str, chat: str, text: str) -> None:
    body = urllib.parse.urlencode({
        "chat_id": chat,
        "text": text,
        "disable_web_page_preview": "true",
    }).encode()
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/sendMessage",
        data=body,
        headers={"content-type": "application/x-www-form-urlencoded"},
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        payload = json.load(resp)
    if not payload.get("ok"):
        raise SystemExit(f"cli-update-relay: telegram refused: {payload}")


def read_state() -> int:
    """How many event lines have already been sent. Count, not byte offset: the file is
    append-only, and a count survives a line being rewritten in place."""
    try:
        with open(STATE_FILE, encoding="utf8") as fh:
            return int(json.load(fh).get("sent_lines", 0))
    except (OSError, ValueError, TypeError):
        return 0


def write_state(sent_lines: int) -> None:
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w", encoding="utf8") as fh:
        json.dump({"sent_lines": sent_lines,
                   "sent_at": datetime.now(timezone.utc).isoformat(timespec="seconds")}, fh)
    os.replace(tmp, STATE_FILE)


def events() -> list[dict]:
    rows = []
    try:
        with open(EVENTS, encoding="utf8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    rows.append({"ts": "", "kind": "unparsed", "text": line})
    except FileNotFoundError:
        return []
    return rows


# A rollout that failed should read as a failure at a glance, before the text is read.
MARK = {
    "canary-failed": "FAILED",
    "rolled-back": "ROLLED BACK",
    "canary-ok": "ok",
    "rolled-out": "ok",
    "seeded": "ok",
}


def compose(new: list[dict]) -> str:
    lines = ["Claude Code fleet update", ""]
    for ev in new[-MAX_EVENTS:]:
        when = str(ev.get("ts", ""))[:16].replace("T", " ")
        kind = str(ev.get("kind", "?"))
        mark = MARK.get(kind, kind)
        lines.append(f"  • [{mark}] {ev.get('text', '')}")
        if when:
            lines.append(f"    {when} UTC")
    if len(new) > MAX_EVENTS:
        lines.append("")
        lines.append(f"({len(new) - MAX_EVENTS} older event(s) not shown — see {EVENTS})")
    return "\n".join(lines)


def main() -> int:
    load_conf()
    ap = argparse.ArgumentParser()
    ap.add_argument("--to", default=os.environ.get("FLEET_CLI_RELAY_ADMIN", "vitaliy"))
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--all", action="store_true", help="ignore the offset; consider every event")
    args = ap.parse_args()

    rows = events()
    already = 0 if args.all else read_state()
    # The file only grows. If it is shorter than our mark it was rotated or truncated, and
    # starting over would re-send history — treat everything in the new file as already seen.
    if already > len(rows):
        write_state(len(rows))
        print(f"cli-update-relay: events file shrank ({already} -> {len(rows)}); re-anchored, nothing sent")
        return 0
    new = rows[already:]
    if not new:
        print("cli-update-relay: no new events")
        return 0

    text = compose(new)
    if args.dry_run:
        print(text)
        return 0

    token, chat = bot_credentials(args.to)
    send(token, chat, text)
    write_state(len(rows))
    print(f"cli-update-relay: notified {args.to} about {len(new)} event(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
