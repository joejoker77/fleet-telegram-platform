#!/usr/bin/env python3
"""compact-governor — switch a tenant's auto-compaction to 200k only while they are
running out of their usage limit, and back to normal (1M) otherwise.

WHY. A conversation that grows to several hundred thousand tokens re-sends all of it on
every turn, so a heavy user burns the 5-hour and weekly limits fast. Compacting at 200k
for everyone fixed that but the lawyers felt it as losing the 1M window (reverted
2026-09-25). So: 1M by default, 200k only for someone genuinely heading for the ceiling.

WHERE THE NUMBERS COME FROM. ~/.claude/usage-snapshot.json, written by the tenant's
status line (tenant-skel/usage-statusline.py) from data Claude Code already receives.
We make NO request to Anthropic — hard requirement, a ban would hit the whole firm.

HOW IT SWITCHES. Types `/autocompact 200000` (or `/autocompact auto` to restore) into the
tenant's main session, the way the entrypoint already hands notices to the pane. The
command applies to the running session at once and Claude Code saves it to settings.json,
so App sessions started afterwards get it too. Verified on the vitaliy pod 2026-09-25:
419k-token session compacted to 73k on the next turn, no restart. A process-level
CLAUDE_CODE_AUTO_COMPACT_WINDOW (/etc/claudeapp/compact*.env) overrides the command, so
such tenants are skipped.

THE RULE, per window (5 h and 7 days): saver on when used% >= THRESHOLD and usage runs
ahead of time (used% > share of the window already elapsed). Examples from Vitaliy:
10% used, 2 h to reset -> no; 60% used, 3 h to reset -> yes; weekly 30%, 2 days left ->
no; weekly 70%, 6 days left -> yes. A window whose reset has passed counts as unknown ->
no. Missing/stale data therefore always falls back to 1M, never to 200k.

NOT AN LLM CALL: reads files, compares numbers, types a command. Safe on a timer.
Opt-in per tenant via TENANTS in /etc/claudeapp/compact-governor.env; empty = no-op.
"""
import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import time

CONF = "/etc/claudeapp/compact-governor.env"
STATE_DIR = "/var/lib/fleet/compact-governor"
HOME_ROOT = "/home"
WINDOWS = (("five_hour", 5 * 3600), ("seven_day", 7 * 86400))
SPINNER = re.compile(r"^\s*[*·✢✺✷✶✱✸✻✽]\s+[^…]*…", re.M)
MAX_FAILS = 3          # consecutive failed switches before backing off
FAIL_BACKOFF = 3600


def log(msg):
    print(f"[{dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds')}] {msg}", flush=True)


def read_env(path):
    out = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return out


def load_conf():
    c = read_env(CONF)
    return {
        "tenants": c.get("TENANTS", "").split(),
        "threshold": float(c.get("THRESHOLD_PCT", "50")),
        "saver": int(c.get("SAVER_WINDOW", "200000")),
        "dwell": int(c.get("DWELL_MIN", "30")) * 60,
    }


def static_override(user):
    """A process-level window beats /autocompact; leave such tenants alone."""
    for p in ("/etc/claudeapp/compact.env", f"/etc/claudeapp/compact-{user}.env"):
        if read_env(p).get("CLAUDE_CODE_AUTO_COMPACT_WINDOW"):
            return p
    return None


def window_hot(w, length, now, threshold):
    if not isinstance(w, dict):
        return False, "no data"
    try:
        used, reset = float(w["used_percentage"]), int(w["resets_at"])
    except (KeyError, TypeError, ValueError):
        return False, "bad data"
    if reset <= now:
        return False, "reset passed"
    elapsed = max(0.0, min(100.0, (1 - (reset - now) / length) * 100))
    hot = used >= threshold and used > elapsed
    return hot, f"{used:.0f}% used, {elapsed:.0f}% of window elapsed"


def decide(snap, now, threshold):
    """Return (want_saver, reason)."""
    if not snap:
        return False, "no snapshot"
    parts, want = [], False
    for key, length in WINDOWS:
        hot, why = window_hot(snap.get(key), length, now, threshold)
        parts.append(f"{key}: {why}{' -> HOT' if hot else ''}")
        want = want or hot
    return want, "; ".join(parts)


def load_json(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default


def save_state(user, st):
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = os.path.join(STATE_DIR, f".{user}.tmp")
    with open(tmp, "w") as f:
        json.dump(st, f)
    os.replace(tmp, os.path.join(STATE_DIR, f"{user}.json"))


def pod_tmux(user, *args):
    cmd = ["podman", "exec", "-e", f"TMUX_TMPDIR={HOME_ROOT}/{user}/.claude",
           f"claude-{user}", "tmux", *args]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=30)


def capture(user, styled=False):
    r = pod_tmux(user, "capture-pane", "-p", *(["-e"] if styled else []), "-S", "-60", "-t", "claude:0")
    return r.stdout if r.returncode == 0 else ""


ANSI = re.compile(r"\x1b\[[0-9;]*m")
# Claude Code shows a prompt suggestion as dim (SGR 2) ghost text after the ❯; it is not in
# the input buffer and typing replaces it. Seen on every firm pane on 2026-09-28.
GHOST = re.compile(r"^(\x1b\[2m[^\x1b]*\x1b\[0m)?$")


def pane_ready(styled):
    """Idle, and nobody has half-typed something into the prompt. `styled` = capture -e."""
    plain = ANSI.sub("", styled)
    if not plain.strip():
        return False, "pane unreadable (pod down?)"
    if SPINNER.search(plain):
        return False, "session busy"
    prompts = [l for l in styled.splitlines() if "❯" in ANSI.sub("", l)]
    if prompts:
        after = prompts[-1].split("❯", 1)[1].lstrip("\xa0 ").rstrip()
        after = re.sub(r"^(\x1b\[[0-9;]*m)*\x1b\[2m", "\x1b[2m", after)  # drop leading resets
        if ANSI.sub("", after).strip() and not GHOST.match(after):
            return False, "prompt holds typed text"
    return True, ""


def switch(user, arg):
    """Type /autocompact <arg> into the main session and confirm it took."""
    styled = capture(user, styled=True)
    ok, why = pane_ready(styled)
    if not ok:
        return False, why
    marker = "Auto-compact window set to"
    before = ANSI.sub("", styled).count(marker)  # an earlier switch may still be on screen
    text = f"/autocompact {arg}"
    if pod_tmux(user, "send-keys", "-t", "claude:0", "-l", "--", text).returncode != 0:
        return False, "send-keys failed"
    pod_tmux(user, "send-keys", "-t", "claude:0", "Enter")
    for _ in range(10):
        time.sleep(1)
        if capture(user).count(marker) > before:
            return True, "confirmed"
    return False, "no confirmation on screen"


def run_one(user, conf, now, dry):
    st = load_json(os.path.join(STATE_DIR, f"{user}.json"), {}) or {}
    mode = st.get("mode", "normal")
    ov = static_override(user)
    if ov:
        log(f"{user}: skipped, static window set in {ov}")
        return
    snap = load_json(f"{HOME_ROOT}/{user}/.claude/usage-snapshot.json")
    want, reason = decide(snap, now, conf["threshold"])
    target = "saver" if want else "normal"
    age = f", snapshot {int((now - snap['ts']) / 60)} min old" if snap and snap.get("ts") else ""
    if target == mode:
        log(f"{user}: stays {mode} ({reason}{age})")
        return
    if now - st.get("since", 0) < conf["dwell"]:
        log(f"{user}: wants {target} but in {mode} < {conf['dwell'] // 60} min, waiting ({reason})")
        return
    if st.get("fails", 0) >= MAX_FAILS and now - st.get("last_try", 0) < FAIL_BACKOFF:
        log(f"{user}: wants {target}, backing off after {st['fails']} failed tries")
        return
    arg = str(conf["saver"]) if target == "saver" else "auto"
    if dry:
        log(f"{user}: WOULD switch {mode} -> {target} (/autocompact {arg}); {reason}{age}")
        return
    ok, why = switch(user, arg)
    if ok:
        save_state(user, {"mode": target, "since": now, "reason": reason, "fails": 0})
        log(f"{user}: switched {mode} -> {target} (/autocompact {arg}); {reason}{age}")
    else:
        st.update(fails=st.get("fails", 0) + 1, last_try=now)
        save_state(user, st)
        log(f"{user}: switch to {target} not done: {why}; retry next run")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dry-run", action="store_true", help="decide and report, type nothing")
    ap.add_argument("--tenant", action="append", help="limit to these tenants")
    ap.add_argument("--restore", metavar="USER", help="put USER back to /autocompact auto and forget state")
    a = ap.parse_args()
    conf = load_conf()
    if a.restore:
        ok, why = switch(a.restore, "auto")
        try:
            os.unlink(os.path.join(STATE_DIR, f"{a.restore}.json"))
        except FileNotFoundError:
            pass
        log(f"{a.restore}: restore to auto -> {'done' if ok else 'NOT done: ' + why}")
        sys.exit(0 if ok else 1)
    tenants = a.tenant or conf["tenants"]
    if not tenants:
        log("no tenants enabled (TENANTS empty in " + CONF + ") — nothing to do")
        return
    now = int(time.time())
    for u in tenants:
        try:
            run_one(u, conf, now, a.dry_run)
        except Exception as e:  # one tenant must never stop the others
            log(f"{u}: error {type(e).__name__}: {e}")


if __name__ == "__main__":
    main()
