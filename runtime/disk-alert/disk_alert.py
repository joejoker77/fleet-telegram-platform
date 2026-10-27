#!/usr/bin/env python3
"""Disk-space alert for the fleet host. No model calls: reads df and, at or above the
threshold, sends the admin a Telegram message through the smart-reminders admin channel.
Alerts on crossing the threshold, then at most once a day while it stays above, and once
when it drops back below. State in /var/lib/disk-alert/state.json.

Watches every path in DISK_ALERT_PATHS (default "/,/home"), each on its own.  Two paths
rather than one because /home moved onto its own 500 GB volume on 2026-10-27: watching
"/" alone would have reported a comfortable 20% for ever while the volume that actually
holds the growth filled up unseen.  Paths on the same filesystem are reported once.
"""
import datetime as dt
import json
import os
import shutil
import sys

sys.path.insert(0, "/opt/smart-reminders")
import smart_reminders as sr  # noqa: E402

THRESHOLD = int(os.environ.get("DISK_ALERT_PCT", "80"))
PATHS = [p for p in os.environ.get("DISK_ALERT_PATHS", "/,/home").split(",") if p.strip()]
STATE = "/var/lib/disk-alert/state.json"


def biggest_homes(n=5):
    rows = []
    for name in os.listdir("/home"):
        p = f"/home/{name}"
        total = 0
        for dp, _, fn in os.walk(p):
            for f in fn:
                try:
                    total += os.lstat(os.path.join(dp, f)).st_size
                except OSError:
                    pass
        rows.append((total, name))
    return ", ".join(f"{name} {size / 1e9:.1f} GB" for size, name in sorted(rows, reverse=True)[:n])


def check(path, st, today, dry):
    """Return the message for this path, if it has anything to say."""
    try:
        u = shutil.disk_usage(path)
    except OSError as exc:
        sys.stderr.write(f"disk-alert: {path}: {exc}\n")
        return None
    pct = round(u.used / u.total * 100)
    # One state record per path, keyed by path; older state files had the two
    # fields at the top level, for "/" only.
    rec = st.setdefault(path, {"above": False, "last_alert": ""})
    msg = None
    if pct >= THRESHOLD and (not rec["above"] or rec["last_alert"] != today):
        msg = (f"{path} is {pct}% full ({u.free / 1e9:.0f} GB free of {u.total / 1e9:.0f} GB). "
               f"Alert threshold is {THRESHOLD}%.")
        if path == "/home" or path == "/":
            msg += f"\nBiggest home folders: {biggest_homes()}"
        if not dry:
            rec.update(above=True, last_alert=today)
    elif pct < THRESHOLD and rec["above"]:
        msg = f"{path} back under {THRESHOLD}%: {pct}% full, {u.free / 1e9:.0f} GB free."
        if not dry:
            rec.update(above=False)
    return msg


def main():
    dry = "--dry-run" in sys.argv
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    st = sr.jload(STATE, {})
    if "above" in st:  # migrate the single-path state written before 2026-10-27
        st = {"/": {"above": st.get("above", False), "last_alert": st.get("last_alert", "")}}
    today = dt.date.today().isoformat()

    seen = set()
    messages = []
    for path in PATHS:
        try:
            dev = os.stat(path).st_dev
        except OSError:
            continue
        if dev in seen:          # same filesystem reached by two names
            continue
        seen.add(dev)
        msg = check(path, st, today, dry)
        if msg:
            messages.append(msg)

    if messages and not dry:
        if not sr.tg_admin("\n\n".join(messages), sr.conf()):
            return 1
    if dry:
        print("\n\n".join(messages) if messages else "nothing to report")
        return 0
    sr.jsave(STATE, st)
    return 0


if __name__ == "__main__":
    sys.exit(main())
