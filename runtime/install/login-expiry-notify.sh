#!/usr/bin/env python3
"""login-expiry-notify — tell the firm's admin whose Claude login is about to lapse.

    login-expiry-notify [--warn-days 5] [--to <tenant>] [--dry-run] [--force] [--json]

WHY. A tenant's login session (`refreshTokenExpiresAt`) lasts ~30 days from /login and is
NOT extended by use. When it lapses the bot simply stops answering: no warning to the
person, no warning to anyone. On 2026-09-17 six of 32 were past expiry, one of them
(sarah-o-brien) had written to her bot that morning and got silence. Only the person
themself can fix it — they must run /login — so the one useful thing we can do is say
whose turn is coming, and early.

NO MODEL, BY DESIGN. This is a plain script on a timer. It must stay that way: the fleet
rule after the 2026-05-22 incident ($360 in a day) is that nothing on a schedule may call
an LLM. If you are tempted to make this "smarter", make it a report and let a human read
it. See memory feedback_no_recurring_llm_calls.

WHAT IT READS. For each tenant home, exactly one field out of ~/.claude/.credentials.json:
the integer `claudeAiOauth.refreshTokenExpiresAt`. Tokens are never read, logged or sent.
Display names come from the account e-mail in ~/.claude.json when present, else from the
username. Tenants whose credentials carry no refreshTokenExpiresAt (our own bots, which
are not in a time-limited org) are skipped — there is nothing to expire.

WHEN IT SPEAKS. Only when the picture CHANGES: a new name entering the warning window, or
an expiry actually landing. A quiet fleet means no message at all, so the admin can trust
that a message means something moved. --force overrides this for a manual run.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone

HOME_ROOT = os.environ.get("FLEET_HOME_ROOT", "/home")
STATE_FILE = os.environ.get("FLEET_EXPIRY_STATE", "/var/lib/fleet/login-expiry.state")
DEFAULT_ADMIN = os.environ.get("FLEET_EXPIRY_ADMIN", "tonysoprano1337")
CONF = "/etc/claudeapp/login-expiry-notify.env"
SKIP = {"cplane"}


def load_conf() -> None:
    """Optional host config; shell-style KEY=value, read before the CLI."""
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


def tenants() -> list[str]:
    try:
        return sorted(d for d in os.listdir(HOME_ROOT)
                      if d not in SKIP and os.path.isdir(os.path.join(HOME_ROOT, d)))
    except OSError:
        return []


def expiry_of(user: str) -> datetime | None:
    """The one field we read. None when the tenant has no time-limited session."""
    path = os.path.join(HOME_ROOT, user, ".claude", ".credentials.json")
    try:
        with open(path, encoding="utf8") as fh:
            blob = json.load(fh)
    except (OSError, ValueError):
        return None
    oauth = blob.get("claudeAiOauth", blob)
    raw = oauth.get("refreshTokenExpiresAt")
    try:
        return datetime.fromtimestamp(int(raw) / 1000, timezone.utc)
    except (TypeError, ValueError):
        return None


def display_name(user: str) -> str:
    pretty = " ".join(p.capitalize() for p in user.replace("_", "-").split("-") if p)
    try:
        with open(os.path.join(HOME_ROOT, user, ".claude.json"), encoding="utf8") as fh:
            email = (json.load(fh).get("oauthAccount") or {}).get("emailAddress")
        if email:
            return f"{pretty} ({email})"
    except (OSError, ValueError):
        pass
    return pretty


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
        raise SystemExit(f"login-expiry-notify: no bot token / chat id for {admin}")
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
        raise SystemExit(f"login-expiry-notify: telegram refused: {payload}")


def read_state() -> str:
    try:
        with open(STATE_FILE, encoding="utf8") as fh:
            return str(json.load(fh).get("signature", ""))
    except (OSError, ValueError):
        return ""


def write_state(signature: str) -> None:
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w", encoding="utf8") as fh:
        json.dump({"signature": signature,
                   "sent_at": datetime.now(timezone.utc).isoformat(timespec="seconds")}, fh)
    os.replace(tmp, STATE_FILE)


def main() -> int:
    load_conf()
    ap = argparse.ArgumentParser()
    ap.add_argument("--warn-days", type=int, default=int(os.environ.get("FLEET_EXPIRY_WARN_DAYS", 5)))
    ap.add_argument("--to", default=DEFAULT_ADMIN)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true", help="send even if nothing changed")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    now = datetime.now(timezone.utc)
    rows = []
    for user in tenants():
        exp = expiry_of(user)
        if exp is None:
            continue
        days = (exp - now).total_seconds() / 86400
        if days <= args.warn_days:
            rows.append({"user": user, "name": display_name(user),
                         "expires": exp.strftime("%Y-%m-%d %H:%M UTC"),
                         "days_left": round(days, 1),
                         "expired": days < 0})
    rows.sort(key=lambda r: r["days_left"])

    # --json is a reporting mode: machine output only, and it never sends.
    if args.json:
        print(json.dumps({"checked": len(tenants()), "flagged": rows}, indent=2))
        return 0

    # The signature deliberately ignores the clock: only WHO and WHICH DAY matter, so a
    # steady picture stays silent while a new name or a lapsed date speaks.
    signature = ";".join(f"{r['user']}:{r['expires'][:10]}:{int(r['expired'])}" for r in rows)
    if not rows:
        write_state("")
        if not args.json:
            print("login-expiry-notify: nothing within the window")
        return 0
    if signature == read_state() and not args.force:
        if not args.json:
            print("login-expiry-notify: unchanged since the last message — staying quiet")
        return 0

    expired = [r for r in rows if r["expired"]]
    soon = [r for r in rows if not r["expired"]]
    lines = ["Claude sign-in expiry report", ""]
    def ago(days: float) -> str:
        whole = abs(int(days))
        if whole == 0:
            return "today"
        return f"{whole} day{'s' if whole != 1 else ''} ago"

    if expired:
        lines.append(f"NOT WORKING NOW — sign-in lapsed ({len(expired)}):")
        for r in expired:
            lines.append(f"  • {r['name']} — expired {r['expires']} ({ago(r['days_left'])})")
        lines.append("")
    if soon:
        lines.append(f"Expiring within {args.warn_days} days ({len(soon)}):")
        for r in soon:
            lines.append(f"  • {r['name']} — {r['expires']} (in {r['days_left']:.1f} days)")
        lines.append("")
    lines.append("A lapsed sign-in means that person's bot stops answering, silently.")
    lines.append("Each person must run /login in their own session — nobody can do it for them.")
    text = "\n".join(lines)

    if args.dry_run:
        print(text)
        return 0

    token, chat = bot_credentials(args.to)
    send(token, chat, text)
    write_state(signature)
    print(f"login-expiry-notify: notified {args.to} about {len(rows)} account(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
