#!/usr/bin/env python3
"""login-expiry-notify — tell people whose Claude login is about to lapse, and the admin.

    login-expiry-notify [--warn-days 3] [--to <tenant>] [--dry-run] [--force] [--json]
                        [--no-personal] [--only <tenant> ...]

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

TELLING THE PERSON THEMSELVES (added 6 Oct 2026). Reporting to an administrator was never
the fix: the administrator cannot sign in for anybody, so the message had to be relayed by
hand and often was not. Where a tenant has the `relogin` helper installed, this now also
starts a sign-in in their own pod at three days, two days and one day, and again once a day
after it has lapsed. They get a link with a button in their own chat and send the code back
as an ordinary message; nothing reaches an administrator's desk at all.

The ladder is 3/2/1 rather than 7/3/1 (Dmitrii's call, 6 Oct 2026): a week's notice is
ignored and then forgotten, and the thing being asked for takes twenty seconds.

Each person hears once per rung, not once per run — the timer ticks daily, and `--force`
does not override that, because forcing a report to an administrator is harmless and
forcing a second link at a lawyer is not. The rungs are per person in
/var/lib/fleet/login-expiry-personal.json; delete a name from it to let a rung fire again.

A tenant without the helper is skipped in silence. That is what makes this safe to roll out
to one person at a time: the installed set IS the enrolled set.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone

HOME_ROOT = os.environ.get("FLEET_HOME_ROOT", "/home")
STATE_FILE = os.environ.get("FLEET_EXPIRY_STATE", "/var/lib/fleet/login-expiry.state")
# Which rung of the ladder each person was last told about, so a daily tick is not a
# daily message. 3, 2, 1 and then 0 — the last meaning "lapsed", which repeats daily.
PERSONAL_STATE = os.environ.get("FLEET_EXPIRY_PERSONAL_STATE",
                                "/var/lib/fleet/login-expiry-personal.json")
TRIGGER = os.environ.get("FLEET_RELOGIN_TRIGGER", "/usr/local/sbin/relogin-trigger")
# Read at call time, not here: load_conf() runs first and only then can the host config
# in CONF have a say. Binding the env var at import would make FLEET_EXPIRY_ADMIN in that
# file silently dead, which is exactly the bug this comment replaces.
DEFAULT_ADMIN = "tonysoprano1337"
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


# ---- telling the person themselves -------------------------------------------------

def has_relogin(user: str) -> bool:
    """The enrolled set is the installed set — see the note at the top about the canary."""
    return os.path.exists(os.path.join(HOME_ROOT, user, "work", "bin", "relogin"))


def rung(days: float) -> int:
    """Which step of the 3/2/1 ladder a tenant is on; 0 once it has lapsed.

    Ceiling, not rounding: at 2.7 days left the honest thing to say is "three days", and
    saying "two" of something that is nearly three is how a person decides the warning
    cannot be trusted.
    """
    if days <= 0:
        return 0
    return max(1, math.ceil(days))


def read_personal() -> dict:
    try:
        with open(PERSONAL_STATE, encoding="utf8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def write_personal(state: dict) -> None:
    os.makedirs(os.path.dirname(PERSONAL_STATE), exist_ok=True)
    tmp = PERSONAL_STATE + ".tmp"
    with open(tmp, "w", encoding="utf8") as fh:
        json.dump(state, fh, indent=2, sort_keys=True)
    os.replace(tmp, PERSONAL_STATE)


def notify_people(rows: list[dict], steps: set[int], dry_run: bool) -> list[str]:
    """Start a sign-in in each enrolled tenant's own pod. Returns a line per action.

    Failures are reported, never raised: one pod that is down must not stop the rest of
    the fleet being warned, nor the admin report that follows.
    """
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    state = read_personal()
    notes = []
    for row in rows:
        user = row["user"]
        if not has_relogin(user):
            continue
        step = rung(row["days_left"])
        if step not in steps and step != 0:
            continue
        seen = state.get(user) or {}
        if step != 0 and seen.get("step") == step:
            continue
        if step == 0 and seen.get("step") == 0 and seen.get("date") == today:
            continue
        reason = "expired" if step == 0 else "warn"
        if dry_run:
            notes.append(f"would start a sign-in for {user} ({reason}, {step} day rung)")
            continue
        try:
            out = subprocess.run([TRIGGER, user, "--reason", reason],
                                 capture_output=True, text=True, timeout=240)
        except (OSError, subprocess.SubprocessError) as exc:
            notes.append(f"{user}: could not start a sign-in: {exc}")
            continue
        if out.returncode != 0:
            notes.append(f"{user}: sign-in not started: "
                         f"{(out.stderr or out.stdout).strip().splitlines()[-1:] or ['?']}")
            continue
        state[user] = {"step": step, "date": today}
        notes.append(f"{user}: sign-in link sent ({reason}, {step} day rung)")
    if not dry_run:
        # Forget anybody who has signed in again, so the ladder starts over next time.
        live = {row["user"] for row in rows}
        for user in list(state):
            if user not in live:
                del state[user]
        write_personal(state)
    return notes


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
    ap.add_argument("--warn-days", type=int, default=int(os.environ.get("FLEET_EXPIRY_WARN_DAYS", 3)))
    ap.add_argument("--to", default=os.environ.get("FLEET_EXPIRY_ADMIN", DEFAULT_ADMIN))
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true", help="send even if nothing changed")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--no-personal", action="store_true",
                    help="report to the admin only; start nobody's sign-in")
    ap.add_argument("--only", nargs="*", default=None,
                    help="consider only these tenants (a canary, or one person's test)")
    ap.add_argument("--steps", default=os.environ.get("FLEET_EXPIRY_PERSONAL_STEPS", "3,2,1"),
                    help="days at which the person is told; the default ladder is 3/2/1")
    args = ap.parse_args()

    now = datetime.now(timezone.utc)
    rows = []
    for user in tenants():
        if args.only is not None and user not in args.only:
            continue
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

    # The people come first, and they come before the quiet check below: whether the
    # ADMIN has heard this already has nothing to do with whether the person has.
    personal: list[str] = []
    if not args.no_personal:
        steps = {int(s) for s in args.steps.split(",") if s.strip().isdigit()}
        personal = notify_people(rows, steps, args.dry_run)
        for line in personal:
            print(f"login-expiry-notify: {line}")

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
    if personal:
        # Say what was already done, so nobody chases a person who has had the link.
        lines.append("")
        lines.append("Sign-in links sent to the people themselves:")
        for line in personal:
            lines.append(f"  • {line}")
        lines.append("")
        lines.append("They tap the button and send the code back in their own chat.")
    missing = [r for r in rows if not has_relogin(r["user"])]
    if missing:
        lines.append("")
        lines.append(f"Not enrolled in self-service sign-in ({len(missing)} of {len(rows)}): "
                     "they must run /login in their own session — nobody can do it for them.")
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
